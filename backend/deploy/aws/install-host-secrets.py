#!/usr/bin/env python3
"""Install the existing beta secrets on EC2 without logging their values.

Run as root on the prepared host, after granting its instance role GetSecretValue
on the three exact secrets. This never creates or rotates a secret. AWS and
OpenSSL output is captured, not sent to SSM command/session logs.
"""

import base64
import fcntl
import hmac
import json
import os
from pathlib import Path
import re
import resource
import shutil
import stat
import subprocess
import sys
import tempfile


REGION = "us-east-2"
PROJECT = "579072312038"
PREFIX = "maptalk/private-beta/"
SECRET_NAMES = ("apple-sign-in", "apple-token-encryption", "backup-encryption")
MEMBERS = ("runtime.env", "apple-sign-in.p8", "compose.env")
PUBLIC_RUNTIME = {
    "MAPTALK_APPLE_CLIENT_ID": "com.chengsi.maptalk",
    "MAPTALK_APPLE_TEAM_ID": "H28S4PM4KP",
    "MAPTALK_APPLE_KEY_ID": "P2TYDWHP4C",
    "MAPTALK_BACKUP_S3_BUCKET": "maptalk-beta-579072312038-us-east-2",
    "MAPTALK_BACKUP_S3_PREFIX": "maptalk/backups/",
}
COMPOSE = {
    "MAPTALK_DOMAIN": "api.maptalkapp.com",
    "MAPTALK_ENV_FILE": "/etc/maptalk/runtime.env",
    "MAPTALK_APPLE_PRIVATE_KEY_HOST_PATH": "/etc/maptalk/apple-sign-in.p8",
    "MAPTALK_DATA_DIRECTORY": "/srv/maptalk/data",
    "MAPTALK_BACKUP_DIRECTORY_HOST": "/srv/maptalk/backups",
    "MAPTALK_CADDY_DATA_DIRECTORY": "/srv/maptalk/caddy-data",
    "MAPTALK_CADDY_CONFIG_DIRECTORY": "/srv/maptalk/caddy-config",
}


class InstallError(Exception):
    """Only fixed, non-secret diagnostic text may be passed to this exception."""


def captured(command, *, data=None, runner=subprocess.run, timeout=45):
    # No inherited AWS keys, profiles, endpoint overrides, proxies, shell hooks,
    # debug flags or credential-process configuration: credentials come from IMDSv2.
    environment = {
        "PATH": "/usr/bin:/bin",
        "HOME": "/nonexistent",
        "AWS_CONFIG_FILE": "/dev/null",
        "AWS_SHARED_CREDENTIALS_FILE": "/dev/null",
        "AWS_EC2_METADATA_V1_DISABLED": "true",
        "AWS_REGION": REGION,
        "AWS_DEFAULT_REGION": REGION,
        "AWS_MAX_ATTEMPTS": "2",
        "AWS_PAGER": "",
    }
    try:
        input_arguments = {"input": data} if data is not None else {"stdin": subprocess.DEVNULL}
        result = runner(command, **input_arguments, stdout=subprocess.PIPE,
                        stderr=subprocess.DEVNULL, env=environment,
                        timeout=timeout, check=False)
        if result.returncode != 0 or len(result.stdout) > 65536:
            raise InstallError("Secret operation failed.")
        return result.stdout
    except Exception:
        # Subprocess errors can include stdout/input bytes; never propagate them.
        raise InstallError("Secret operation failed.") from None


def get_secret(short_name, *, runner=subprocess.run):
    if short_name not in SECRET_NAMES:
        raise InstallError("Unexpected secret name.")
    name = PREFIX + short_name
    output = captured([
        "/usr/bin/aws", "secretsmanager", "get-secret-value",
        "--secret-id", name, "--version-stage", "AWSCURRENT",
        "--region", REGION, "--output", "json", "--no-cli-pager",
        "--cli-connect-timeout", "10", "--cli-read-timeout", "20",
    ], runner=runner)
    try:
        result = json.loads(output)
        arn_pattern = rf"arn:aws:secretsmanager:{REGION}:{PROJECT}:secret:{re.escape(name)}-[A-Za-z0-9]{{6}}"
        if (not isinstance(result, dict) or result.get("Name") != name
                or not isinstance(result.get("ARN"), str)
                or not re.fullmatch(arn_pattern, result["ARN"])
                or not isinstance(result.get("VersionStages"), list)
                or "AWSCURRENT" not in result["VersionStages"]
                or "SecretBinary" in result
                or not isinstance(result.get("SecretString"), str)
                or not 0 < len(result["SecretString"]) <= 4096):
            raise ValueError()
        return result["SecretString"]
    except Exception:
        raise InstallError("Secret identity or format validation failed.") from None


def validate_apple_key(value, *, runner=subprocess.run):
    if (not value.startswith("-----BEGIN PRIVATE KEY-----\n")
            or not value.endswith(("\n-----END PRIVATE KEY-----", "\n-----END PRIVATE KEY-----\n"))
            or value.count("-----BEGIN ") != 1 or "\r" in value):
        raise InstallError("Apple key validation failed.")
    try:
        pem = value.encode("ascii")
        public = captured(["/usr/bin/openssl", "pkey", "-pubout", "-outform", "DER", "-passin", "pass:"],
                          data=pem, runner=runner)
        # The complete P-256 SPKI header, followed by one uncompressed EC point.
        prefix = bytes.fromhex("3059301306072a8648ce3d020106082a8648ce3d03010703420004")
        if len(public) != 91 or not public.startswith(prefix):
            raise ValueError()
        # Apple downloads may omit the final LF. Preserve the existing bytes;
        # accepting this valid PEM representation must not rotate/normalize it.
        return pem
    except Exception:
        raise InstallError("Apple key validation failed.") from None


def decode_encryption_key(value):
    try:
        key = base64.b64decode(value, validate=True)
        if len(key) != 32 or base64.b64encode(key).decode("ascii") != value:
            raise ValueError()
        return key
    except Exception:
        raise InstallError("Encryption key validation failed.") from None


def make_payload(secrets, *, runner=subprocess.run):
    if set(secrets) != set(SECRET_NAMES):
        raise InstallError("Unexpected secret set.")
    apple = validate_apple_key(secrets["apple-sign-in"], runner=runner)
    token = decode_encryption_key(secrets["apple-token-encryption"])
    backup = decode_encryption_key(secrets["backup-encryption"])
    if hmac.compare_digest(token, backup):
        raise InstallError("Encryption keys must be independent.")
    runtime = dict(PUBLIC_RUNTIME)
    runtime["MAPTALK_APPLE_TOKEN_ENCRYPTION_KEY"] = secrets["apple-token-encryption"]
    runtime["MAPTALK_BACKUP_ENCRYPTION_KEY"] = secrets["backup-encryption"]
    encode_env = lambda values: "".join(f"{key}={value}\n" for key, value in values.items()).encode("ascii")
    return {"runtime.env": encode_env(runtime), "apple-sign-in.p8": apple,
            "compose.env": encode_env(COMPOSE)}


def private_directory(directory, owner_uid):
    directory = Path(directory)
    if not directory.is_absolute() or ".." in directory.parts:
        raise InstallError("Unsafe configuration directory.")
    for path in (directory, *directory.parents):
        item = path.lstat()
        if (not stat.S_ISDIR(item.st_mode) or item.st_uid not in (0, owner_uid)
                or (item.st_mode & 0o022 and not (item.st_uid == 0 and item.st_mode & stat.S_ISVTX))):
            raise InstallError("Unsafe configuration directory.")
    item = directory.lstat()
    if item.st_uid != owner_uid or stat.S_IMODE(item.st_mode) != 0o700:
        raise InstallError("Unsafe configuration directory.")
    return directory


def read_file(directory_fd, name, uid, gid, mode):
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory_fd)
    try:
        item = os.fstat(fd)
        if (not stat.S_ISREG(item.st_mode) or item.st_nlink != 1
                or item.st_uid != uid or item.st_gid != gid
                or stat.S_IMODE(item.st_mode) != mode or item.st_size > 16384):
            raise InstallError("Unsafe existing configuration file.")
        with os.fdopen(fd, "rb", closefd=False) as stream:
            return stream.read(16385)
    finally:
        os.close(fd)


def install_payload(directory, payload, *, owner_uid=0, owner_gid=0, app_uid=1000, app_gid=1000):
    """Private staging + no-replace installs; never overwrite or rotate a key.

    The host bootstrap owns the existing directory and marker file. Individual
    installs are atomic. On failure, remove only this invocation's new files;
    an interrupted partial installation is refused on the next invocation.
    """
    if set(payload) != set(MEMBERS) or any(not isinstance(value, bytes) or not 0 < len(value) <= 16384
                                        for value in payload.values()):
        raise InstallError("Invalid configuration payload.")
    directory = private_directory(directory, owner_uid)
    directory_fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    lock_fd = None
    staging = None
    created = []
    identities = {name: (app_uid, app_gid, 0o400) if name == "apple-sign-in.p8"
                  else (owner_uid, owner_gid, 0o600) for name in MEMBERS}
    try:
        lock_fd = os.open(".install-secrets.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK,
                          0o600, dir_fd=directory_fd)
        lock = os.fstat(lock_fd)
        if (not stat.S_ISREG(lock.st_mode) or lock.st_nlink != 1 or lock.st_uid != owner_uid
                or lock.st_gid != owner_gid or stat.S_IMODE(lock.st_mode) != 0o600):
            raise InstallError("Unsafe installation lock.")
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        existing = []
        for name in MEMBERS:
            try:
                os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
                existing.append(name)
            except FileNotFoundError:
                pass
        if existing:
            if len(existing) != len(MEMBERS):
                raise InstallError("Incomplete configuration; refusing to replace it.")
            for name in MEMBERS:
                if not hmac.compare_digest(read_file(directory_fd, name, *identities[name]), payload[name]):
                    raise InstallError("Existing configuration differs; refusing to replace it.")
            return True
        staging = Path(tempfile.mkdtemp(prefix=".secrets-stage-", dir=directory))
        os.chmod(staging, 0o700)
        for name in MEMBERS:
            path = staging / name
            uid, gid, mode = identities[name]
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            try:
                with os.fdopen(fd, "wb", closefd=False) as stream:
                    stream.write(payload[name])
                    stream.flush()
                os.fchown(fd, uid, gid)
                os.fchmod(fd, mode)
                os.fsync(fd)
            finally:
                os.close(fd)
        for name in MEMBERS:
            # link is an atomic create-if-absent (rename would overwrite).
            path = staging / name
            item = path.lstat()
            os.link(path, name, dst_dir_fd=directory_fd, follow_symlinks=False)
            created.append((name, item.st_ino, item.st_dev))
            path.unlink()
        os.fsync(directory_fd)
        for name in MEMBERS:
            if not hmac.compare_digest(read_file(directory_fd, name, *identities[name]), payload[name]):
                raise InstallError("Installed configuration verification failed.")
        return False
    except BaseException:
        for name, inode, device in reversed(created):
            item = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
            if (item.st_ino, item.st_dev) == (inode, device):
                os.unlink(name, dir_fd=directory_fd)
        raise
    finally:
        if staging is not None:
            shutil.rmtree(staging)
        if lock_fd is not None:
            os.close(lock_fd)
        os.close(directory_fd)


def main():
    try:
        if len(sys.argv) != 1 or os.geteuid() != 0:
            raise InstallError("Run without arguments as root on the prepared host.")
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        os.umask(0o077)
        private_directory("/etc/maptalk", 0)
        secrets = {name: get_secret(name) for name in SECRET_NAMES}
        reused = install_payload("/etc/maptalk", make_payload(secrets))
        print("Host secrets verified and reused." if reused else "Host secrets installed.")
        return 0
    except BaseException:
        print("Host secret installation failed; no credentials were logged.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
