"""Isolated installer checks: generated test keys, temporary files, no AWS calls."""

import base64
import contextlib
import fcntl
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "deploy/aws/install-host-secrets.py"
spec = importlib.util.spec_from_file_location("host_secrets", SCRIPT)
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


def key_for(curve):
    result = subprocess.run(["/usr/bin/openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", f"ec_paramgen_curve:{curve}",
                             "-pkeyopt", "ec_param_enc:named_curve"],
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=True)
    return result.stdout.decode("ascii")


class HostSecretsChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.apple = key_for("prime256v1")

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="maptalk-host-secrets-test-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name).resolve()
        os.chmod(self.directory, 0o700)
        self.ids = dict(owner_uid=os.getuid(), owner_gid=os.getgid(), app_uid=os.getuid(), app_gid=os.getgid())
        self.values = {
            "apple-sign-in": self.apple,
            "apple-token-encryption": base64.b64encode(bytes(range(32))).decode("ascii"),
            "backup-encryption": base64.b64encode(bytes(range(32, 64))).decode("ascii"),
        }

    def payload(self):
        return installer.make_payload(self.values)

    def install(self, payload=None):
        return installer.install_payload(self.directory, self.payload() if payload is None else payload, **self.ids)

    def response(self, short="apple-sign-in", **changes):
        name = installer.PREFIX + short
        value = {"Name": name,
                 "ARN": f"arn:aws:secretsmanager:us-east-2:579072312038:secret:{name}-a1B2c3",
                 "VersionStages": ["AWSCURRENT"], "SecretString": self.values[short]}
        value.update(changes)
        return json.dumps(value).encode("utf8")

    def test_cli_is_read_only_scoped_and_instance_role_only(self):
        calls = []

        def runner(command, **kwargs):
            calls.append((command, kwargs))
            return subprocess.CompletedProcess(command, 0, self.response(), b"")

        with patch.dict(os.environ, {"AWS_ACCESS_KEY_ID": "DO_NOT_INHERIT", "AWS_ENDPOINT_URL": "https://example.invalid",
                                    "AWS_PROFILE": "bad", "HTTPS_PROXY": "https://example.invalid"}):
            self.assertEqual(installer.get_secret("apple-sign-in", runner=runner), self.apple)
        command, kwargs = calls[0]
        self.assertEqual(command[:3], ["/usr/bin/aws", "secretsmanager", "get-secret-value"])
        self.assertEqual(command[command.index("--region") + 1], "us-east-2")
        self.assertEqual(command[command.index("--secret-id") + 1], "maptalk/private-beta/apple-sign-in")
        self.assertEqual(command[command.index("--version-stage") + 1], "AWSCURRENT")
        self.assertEqual(kwargs["stderr"], subprocess.DEVNULL)
        self.assertEqual(kwargs["stdout"], subprocess.PIPE)
        self.assertEqual(kwargs["env"]["AWS_CONFIG_FILE"], "/dev/null")
        self.assertEqual(kwargs["env"]["AWS_SHARED_CREDENTIALS_FILE"], "/dev/null")
        self.assertEqual(kwargs["env"]["AWS_EC2_METADATA_V1_DISABLED"], "true")
        for name in ("AWS_ACCESS_KEY_ID", "AWS_PROFILE", "HTTPS_PROXY", "AWS_ENDPOINT_URL"):
            self.assertNotIn(name, kwargs["env"])
        self.assertNotIn(self.apple, command)
        self.assertEqual(len(calls), 1)

    def test_secret_identity_and_current_version_are_validated(self):
        alterations = [
            {"Name": "other"},
            {"ARN": "arn:aws:secretsmanager:us-east-1:579072312038:secret:maptalk/private-beta/apple-sign-in-a1B2c3"},
            {"ARN": "arn:aws:secretsmanager:us-east-2:000000000000:secret:maptalk/private-beta/apple-sign-in-a1B2c3"},
            {"ARN": "arn:aws:secretsmanager:us-east-2:579072312038:secret:maptalk/private-beta/apple-sign-in-a1B2c3-extra"},
            {"ARN": None}, {"VersionStages": ["AWSPREVIOUS"]}, {"VersionStages": "AWSCURRENT"},
            {"SecretBinary": "anything"}, {"SecretString": None}, {"SecretString": ""}, {"SecretString": "x" * 4097},
        ]
        for change in alterations:
            with self.subTest(change=tuple(change)):
                runner = lambda command, **kwargs: subprocess.CompletedProcess(command, 0, self.response(**change), b"")
                with self.assertRaises(installer.InstallError):
                    installer.get_secret("apple-sign-in", runner=runner)
        with self.assertRaises(installer.InstallError):
            installer.get_secret("unexpected", runner=lambda *args, **kwargs: self.fail("Must not call AWS"))

    def test_external_failures_never_include_captured_values(self):
        sentinel = b"DO_NOT_LOG_TEST_SECRET"
        variants = [
            lambda command, **kwargs: subprocess.CompletedProcess(command, 1, sentinel, sentinel),
            lambda command, **kwargs: subprocess.CompletedProcess(command, 0, b"x" * 65537, sentinel),
            lambda command, **kwargs: subprocess.CompletedProcess(command, 0, sentinel, sentinel),
        ]
        for runner in variants:
            with self.assertRaises(installer.InstallError) as error:
                installer.get_secret("apple-sign-in", runner=runner)
            self.assertNotIn(sentinel.decode(), str(error.exception))
        def failed(*args, **kwargs):
            raise subprocess.TimeoutExpired("aws", 45, output=sentinel, stderr=sentinel)
        with self.assertRaises(installer.InstallError) as error:
            installer.get_secret("apple-sign-in", runner=failed)
        self.assertNotIn(sentinel.decode(), str(error.exception))

    def test_payload_preserves_keys_and_existing_public_configuration(self):
        payload = self.payload()
        self.assertEqual(set(payload), set(installer.MEMBERS))
        self.assertEqual(payload["apple-sign-in.p8"], self.apple.encode())
        runtime = dict(line.split("=", 1) for line in payload["runtime.env"].decode().splitlines())
        self.assertEqual(runtime["MAPTALK_APPLE_TOKEN_ENCRYPTION_KEY"], self.values["apple-token-encryption"])
        self.assertEqual(runtime["MAPTALK_BACKUP_ENCRYPTION_KEY"], self.values["backup-encryption"])
        self.assertEqual(runtime["MAPTALK_APPLE_CLIENT_ID"], "com.chengsi.maptalk")
        self.assertEqual(runtime["MAPTALK_APPLE_KEY_ID"], "P2TYDWHP4C")
        self.assertEqual(runtime["MAPTALK_APPLE_TEAM_ID"], "H28S4PM4KP")
        self.assertEqual(runtime["MAPTALK_BACKUP_S3_BUCKET"], "maptalk-beta-579072312038-us-east-2")
        self.assertIn(b"MAPTALK_DOMAIN=api.maptalkapp.com\n", payload["compose.env"])
        self.assertIn(b"MAPTALK_APPLE_PRIVATE_KEY_HOST_PATH=/etc/maptalk/apple-sign-in.p8\n", payload["compose.env"])
        self.assertNotIn(b"AWS_ACCESS_KEY", payload["runtime.env"])

    def test_apple_key_requires_an_unencrypted_valid_p256_key(self):
        for pem in [key_for("secp384r1"), "not a key", self.apple + self.apple,
                    self.apple.replace("PRIVATE KEY", "ENCRYPTED PRIVATE KEY"), self.apple.replace("\n", "\r\n")]:
            with self.assertRaises(installer.InstallError):
                installer.make_payload({**self.values, "apple-sign-in": pem})

    def test_apple_key_accepts_optional_final_lf_without_changing_original_bytes(self):
        # A downloaded Apple .p8 can have no LF after its footer. Exercise the
        # real OpenSSL path with a generated test key, not a mocked DER response.
        without_lf = self.apple.removesuffix("\n")
        self.assertFalse(without_lf.endswith("\n"))
        for pem in [without_lf, without_lf + "\n"]:
            payload = installer.make_payload({**self.values, "apple-sign-in": pem})
            self.assertEqual(payload["apple-sign-in.p8"], pem.encode("ascii"))
        payload = installer.make_payload({**self.values, "apple-sign-in": without_lf})
        self.assertFalse(self.install(payload))
        self.assertTrue(self.install(payload))
        self.assertEqual((self.directory / "apple-sign-in.p8").read_bytes(), without_lf.encode("ascii"))

    def test_apple_key_rejects_extra_data_outside_single_pem_block(self):
        without_lf = self.apple.removesuffix("\n")
        for pem in [without_lf + "\n\n", without_lf + "suffix", self.apple + "suffix\n",
                    "prefix\n" + self.apple, self.apple + without_lf,
                    without_lf.replace("\n-----END", "-----END")]:
            with self.assertRaises(installer.InstallError):
                installer.make_payload({**self.values, "apple-sign-in": pem})

    def test_encryption_keys_require_canonical_independent_32_byte_values(self):
        for value in ["!", "", "A" * 44, self.values["apple-token-encryption"] + "\n",
                      base64.b64encode(b"short").decode(), self.values["backup-encryption"]]:
            with self.assertRaises(installer.InstallError):
                installer.make_payload({**self.values, "apple-token-encryption": value})
        with self.assertRaises(installer.InstallError):
            installer.make_payload({**self.values, "extra": "bad"})

    def test_install_creates_private_files_and_preserves_bootstrap_marker(self):
        marker = self.directory / "host-bootstrap-version"
        marker.write_text("existing-bootstrap\n")
        self.assertFalse(self.install())
        self.assertEqual(marker.read_text(), "existing-bootstrap\n")
        self.assertEqual({path.name for path in self.directory.iterdir()},
                         set(installer.MEMBERS) | {".install-secrets.lock", "host-bootstrap-version"})
        for name, value in self.payload().items():
            path = self.directory / name
            self.assertEqual(path.read_bytes(), value)
            self.assertEqual(path.stat().st_mode & 0o777, 0o400 if name == "apple-sign-in.p8" else 0o600)
            self.assertEqual(path.stat().st_nlink, 1)
            self.assertEqual(path.stat().st_uid, os.getuid())

    def test_rerun_never_replaces_or_rotates_existing_files(self):
        self.install()
        before = {name: ((self.directory / name).stat().st_ino, (self.directory / name).read_bytes())
                  for name in installer.MEMBERS}
        self.assertTrue(self.install())
        for name, (inode, content) in before.items():
            self.assertEqual((self.directory / name).stat().st_ino, inode)
            self.assertEqual((self.directory / name).read_bytes(), content)

    def test_changed_or_partial_installations_fail_without_modification(self):
        self.install()
        runtime = (self.directory / "runtime.env").read_bytes()
        changed = {**self.payload(), "runtime.env": b"do not overwrite\n"}
        with self.assertRaisesRegex(installer.InstallError, "differs"):
            self.install(changed)
        self.assertEqual((self.directory / "runtime.env").read_bytes(), runtime)
        (self.directory / "compose.env").unlink()
        with self.assertRaisesRegex(installer.InstallError, "Incomplete"):
            self.install()
        self.assertEqual((self.directory / "runtime.env").read_bytes(), runtime)
        self.assertFalse((self.directory / "compose.env").exists())

    def test_file_symlinks_hardlinks_and_broad_permissions_are_rejected(self):
        self.install()
        runtime = self.directory / "runtime.env"
        os.chmod(runtime, 0o644)
        with self.assertRaises(installer.InstallError):
            self.install()
        os.chmod(runtime, 0o600)
        alias = self.directory / "linked"
        os.link(runtime, alias)
        with self.assertRaises(installer.InstallError):
            self.install()
        alias.unlink()
        runtime.rename(alias)
        runtime.symlink_to(alias)
        with self.assertRaises(OSError):
            self.install()
        self.assertTrue(runtime.is_symlink())

    def test_unsafe_directory_or_symlink_parent_is_rejected(self):
        os.chmod(self.directory, 0o755)
        with self.assertRaises(installer.InstallError):
            self.install()
        os.chmod(self.directory, 0o700)
        actual = self.directory / "actual"
        actual.mkdir(mode=0o700)
        link = self.directory / "link"
        link.symlink_to(actual, target_is_directory=True)
        with self.assertRaises(installer.InstallError):
            installer.install_payload(link, self.payload(), **self.ids)
        nested = actual / "nested"
        nested.mkdir(mode=0o700)
        with self.assertRaises(installer.InstallError):
            installer.install_payload(link / "nested", self.payload(), **self.ids)
        self.assertEqual(list(nested.iterdir()), [])

    def test_mid_install_failure_rolls_back_only_new_files(self):
        original = installer.os.link
        count = 0
        def failed_link(*args, **kwargs):
            nonlocal count
            count += 1
            if count == 2:
                raise OSError("simulated installation failure")
            return original(*args, **kwargs)
        with patch.object(installer.os, "link", failed_link):
            with self.assertRaises(OSError):
                self.install()
        self.assertEqual({path.name for path in self.directory.iterdir()}, {".install-secrets.lock"})
        self.assertFalse(self.install())

    def test_concurrent_file_creation_cannot_be_overwritten(self):
        original = installer.os.link
        count = 0
        def concurrent_link(src, dst, **kwargs):
            nonlocal count
            count += 1
            if count == 2:
                (self.directory / dst).write_bytes(b"existing-writer-content")
            return original(src, dst, **kwargs)
        with patch.object(installer.os, "link", concurrent_link):
            with self.assertRaises(FileExistsError):
                self.install()
        self.assertEqual((self.directory / "apple-sign-in.p8").read_bytes(), b"existing-writer-content")
        self.assertFalse((self.directory / "runtime.env").exists())
        self.assertFalse(any(path.name.startswith(".secrets-stage-") for path in self.directory.iterdir()))

    def test_lock_prevents_concurrent_installation_and_rejects_symlinks(self):
        lock = self.directory / ".install-secrets.lock"
        lock.touch(mode=0o600)
        with lock.open("r+") as stream:
            fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(BlockingIOError):
                self.install()
        lock.unlink()
        target = self.directory / "target"
        target.touch(mode=0o600)
        lock.symlink_to(target)
        with self.assertRaises(OSError):
            self.install()

    def test_main_suppresses_all_failure_details(self):
        stderr, stdout = io.StringIO(), io.StringIO()
        with patch.object(installer.sys, "argv", [str(SCRIPT)]), patch.object(installer.os, "geteuid", return_value=0), \
                patch.object(installer.resource, "setrlimit"), patch.object(installer.os, "umask"), \
                patch.object(installer, "private_directory"), \
                patch.object(installer, "get_secret", side_effect=RuntimeError("DO_NOT_LOG_PRIVATE_VALUE")), \
                contextlib.redirect_stderr(stderr), contextlib.redirect_stdout(stdout):
            self.assertEqual(installer.main(), 1)
        self.assertEqual(stdout.getvalue(), "")
        self.assertEqual(stderr.getvalue(), "Host secret installation failed; no credentials were logged.\n")

    def test_main_refuses_arguments_or_non_root_before_fetching_any_secret(self):
        for argv, uid in [([str(SCRIPT), "--secret", "bad"], 0), ([str(SCRIPT)], 501)]:
            with patch.object(installer.sys, "argv", argv), patch.object(installer.os, "geteuid", return_value=uid), \
                    patch.object(installer, "get_secret", side_effect=AssertionError("Must not fetch")) as fetch, \
                    contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(installer.main(), 1)
                fetch.assert_not_called()


if __name__ == "__main__":
    unittest.main()
