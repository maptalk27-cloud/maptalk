#!/usr/bin/env bash
# Amazon Linux 2023 / Graviton only. Run as root through SSM, NOT on a laptop.
# Usage: bash bootstrap-host.sh vol-0123456789abcdef0 [--initialize-empty-volume]
# The operator must verify this exact 20 GiB EBS volume is encrypted and retained
# on instance termination. Never pass keys, passwords or other secrets here.
# No AWS resources are created by this script.
set -euo pipefail
umask 077

# Reviewed official ARM64 release digests on 2026-10-20. Updates are deliberate.
# https://github.com/docker/compose/releases/tag/v5.6.0
# https://github.com/docker/buildx/releases/tag/v0.37.2
COMPOSE_VERSION=v5.6.0
COMPOSE_SHA256=733ec76717ceb59052a9609b9dadfb523b2df8eab57a54212872d10a58078ea2
BUILDX_VERSION=v0.37.2
BUILDX_SHA256=efa38cb7aa7db2dbb9ad049b00b0a9737f66f033626177b5a4e845184ad7ab29
DATA_MOUNT=/srv/maptalk

die() { printf 'MapTalk bootstrap: %s\n' "$*" >&2; exit 1; }
log() { printf 'MapTalk bootstrap: %s\n' "$*"; }
is_block_device() { [[ -b "$1" ]]; }

validate_volume_id() {
  [[ "$1" =~ ^vol-([0-9a-f]{8}|[0-9a-f]{17})$ ]] || die 'An exact EBS volume ID is required.'
}

select_data_device() {
  local expected="${1//-/}" path type serial selected=''
  # NVMe numbering can change across boots. EBS exposes the volume ID as serial.
  while read -r path type serial; do
    if [[ "$type" == disk && "${serial//-/}" == "$expected" ]]; then
      [[ -z "$selected" ]] || die 'More than one disk matched the EBS volume ID.'
      selected="$path"
    fi
  done < <(lsblk -dn -o PATH,TYPE,SERIAL)
  [[ -n "$selected" ]] || die 'The requested EBS volume is not attached; no disk was changed.'
  printf '%s\n' "$selected"
}

validate_data_device() {
  local device="$1" root ancestors children mounts mountpoint path
  is_block_device "$device" || die 'The selected device is not a block device.'
  [[ "$(lsblk -dn -o MODEL "$device" | xargs)" == 'Amazon Elastic Block Store' ]] || die 'Not an Amazon EBS device.'
  [[ "$(lsblk -dn -o RO "$device" | xargs)" == 0 ]] || die 'The data device is read-only.'
  [[ "$(lsblk -bdn -o SIZE "$device" | xargs)" == 21474836480 ]] || die 'Expected the approved 20 GiB data volume.'
  root="$(findmnt -rn -o SOURCE /)"
  [[ -n "$root" ]] || die 'Cannot identify the root filesystem.'
  ancestors="$(lsblk -snr -o PATH "$root")"
  [[ -n "$ancestors" ]] || die 'Cannot identify root disk ancestry.'
  while read -r path; do
    [[ "$path" != "$device" ]] || die 'Refusing to use the root disk.'
  done <<< "$ancestors"
  children="$(lsblk -nr -o PATH "$device")"
  [[ "$children" == "$device" ]] || die 'Partitioned or layered disks require manual review; nothing was formatted.'
  mounts="$(lsblk -nr -o MOUNTPOINTS "$device")"
  while read -r mountpoint; do
    case "$mountpoint" in ''|/srv/maptalk|/var/lib/containerd) ;; *) die 'Data disk is mounted elsewhere; refusing to change it.' ;; esac
  done <<< "$mounts"
}

prepare_filesystem() {
  local device="$1" initialize="$2" type='' probe_status=0 signatures
  type="$(blkid -p -s TYPE -o value "$device")" || probe_status=$?
  signatures="$(wipefs --no-act --noheadings --output TYPE "$device" | xargs)"
  if [[ "$probe_status" == 0 && "$type" == ext4 && "$signatures" == ext4 ]]; then
    return # Existing content is retained; never mkfs an existing filesystem.
  fi
  [[ "$probe_status" == 2 && -z "$type" && -z "$signatures" ]] || die 'Unknown filesystem/signature; refusing to format.'
  [[ "$initialize" == yes ]] || die 'Empty disk: rerun with --initialize-empty-volume only after verifying it is a new volume.'
  [[ -z "$(lsblk -nr -o MOUNTPOINTS "$device" | xargs)" ]] || die 'Refusing to format a mounted disk.'
  # No -F: mkfs keeps its own mounted-device and filesystem safety checks.
  mkfs.ext4 -m 0 -L maptalk-data "$device"
}

# Never overwrite a locally customized configuration or follow a symlink.
write_once() {
  local path="$1" mode="$2" candidate
  [[ ! -L "$path" ]] || die "Refusing a symlink at $path."
  candidate="$(mktemp "$WORK_DIR/config.XXXXXX")"
  cat > "$candidate"
  if [[ -e "$path" ]]; then
    cmp -s "$candidate" "$path" || die "Existing configuration differs at $path; review it manually."
  else
    install -o 0 -g 0 -m "$mode" "$candidate" "$path"
  fi
  rm -f "$candidate"
}

ensure_fstab_entry() {
  local source="$1" target="$2" type="$3" options="$4" pass="$5" existing
  existing="$(awk -v dest="$target" '$1 !~ /^#/ && $2 == dest { print }' /etc/fstab)"
  if [[ -n "$existing" ]]; then
    [[ "$existing" == "$source $target $type $options 0 $pass" ]] || die "Conflicting fstab entry for $target."
  else
    # Do not silently mount one filesystem at an additional unexpected location.
    ! awk -v src="$source" '$1 == src { found=1 } END { exit !found }' /etc/fstab || die 'This fstab source is already used elsewhere.'
    printf '%s %s %s %s 0 %s\n' "$source" "$target" "$type" "$options" "$pass" >> /etc/fstab
  fi
}

require_empty_directory() {
  [[ ! -L "$1" ]] || die "Refusing a symlink at $1."
  if [[ -d "$1" ]]; then
    [[ -z "$(find "$1" -mindepth 1 -maxdepth 1 -print -quit)" ]] || die "Existing files at $1 require a reviewed migration."
  fi
}

install_plugin() {
  local name="$1" url="$2" digest="$3" path="/usr/local/lib/docker/cli-plugins/$1" download
  [[ ! -L "$path" ]] || die "Refusing a symlink at $path."
  if [[ -e "$path" ]]; then
    [[ "$(sha256sum "$path" | cut -d ' ' -f 1)" == "$digest" ]] || die "Installed $name differs from the reviewed digest."
    return
  fi
  download="$(mktemp "$WORK_DIR/download.XXXXXX")"
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    --tlsv1.2 --connect-timeout 15 --max-time 180 --retry 3 --output "$download" "$url"
  printf '%s  %s\n' "$digest" "$download" | sha256sum --check --status || die "$name checksum mismatch."
  install -o 0 -g 0 -m 0755 "$download" "$path"
  rm -f "$download"
}

main() {
  [[ "$#" -ge 1 && "$#" -le 2 ]] || die 'Usage: bootstrap-host.sh vol-ID [--initialize-empty-volume]'
  local volume_id="$1" initialize=no device uuid current
  validate_volume_id "$volume_id"
  if [[ "$#" == 2 ]]; then
    [[ "$2" == --initialize-empty-volume ]] || die 'Unrecognized option.'
    initialize=yes
  fi
  [[ "$EUID" == 0 ]] || die 'Run as root through SSM on the target EC2 instance.'
  [[ "$(uname -s)" == Linux && "$(uname -m)" == aarch64 ]] || die 'Amazon Linux 2023 ARM64 is required.'
  # This is a trusted OS-owned file, never a deployment-supplied env file.
  . /etc/os-release
  [[ "$ID" == amzn && "$VERSION_ID" == 2023 ]] || die 'Amazon Linux 2023 is required.'
  exec 9>/run/maptalk-bootstrap.lock
  flock -n 9 || die 'Another host bootstrap is running.'
  for command in lsblk findmnt blkid wipefs mkfs.ext4 mountpoint curl sha256sum; do
    command -v "$command" >/dev/null || die "Missing base OS utility: $command."
  done
  device="$(select_data_device "$volume_id")"
  validate_data_device "$device"
  prepare_filesystem "$device" "$initialize"
  uuid="$(blkid -s UUID -o value "$device")"
  [[ "$uuid" =~ ^[0-9a-f-]{36}$ ]] || die 'Cannot identify the data filesystem UUID.'

  # nofail leaves SSM recoverable if the disk is missing. The services below
  # explicitly require the actual mount and UUID, so they still fail closed.
  if ! mountpoint -q "$DATA_MOUNT"; then
    require_empty_directory "$DATA_MOUNT"
    install -d -o 0 -g 0 -m 0755 "$DATA_MOUNT"
  else
    [[ "$(findmnt -rn -M "$DATA_MOUNT" -o UUID)" == "$uuid" ]] || die 'A different volume is mounted at /srv/maptalk.'
  fi
  ensure_fstab_entry "UUID=$uuid" "$DATA_MOUNT" ext4 defaults,nosuid,nodev,nofail,x-systemd.device-timeout=30s 2
  mountpoint -q "$DATA_MOUNT" || mount "$DATA_MOUNT"
  [[ "$(findmnt -rn -M "$DATA_MOUNT" -o UUID)" == "$uuid" ]] || die 'The expected data mount is unavailable.'

  # Keep container layers/build cache off the 10 GiB root disk. The 20 GiB data
  # disk is shared with SQLite and backups, so deployment must check free space
  # and prune obsolete build cache deliberately (never application volumes).
  for current in /etc/maptalk "$DATA_MOUNT/docker" "$DATA_MOUNT/containerd" "$DATA_MOUNT/releases"; do
    [[ ! -L "$current" ]] || die "Refusing a symlink at $current."
  done
  install -d -o 0 -g 0 -m 0700 /etc/maptalk "$DATA_MOUNT/docker" "$DATA_MOUNT/containerd"
  install -d -o 0 -g 0 -m 0755 "$DATA_MOUNT/releases"
  for current in data backups caddy-data caddy-config; do
    [[ ! -L "$DATA_MOUNT/$current" ]] || die 'Persistent directory cannot be a symlink.'
    # Only directory metadata is set; existing contents are never recursively chowned.
    install -d -o 1000 -g 1000 -m 0700 "$DATA_MOUNT/$current"
  done

  if [[ ! -e /etc/maptalk/host-bootstrap-version ]]; then
    for current in docker.service docker.socket containerd.service; do
      ! systemctl is-active --quiet "$current" || die 'An existing container runtime requires manual migration.'
    done
    require_empty_directory /var/lib/docker
    require_empty_directory /var/lib/containerd
    # RPM installation must not start a runtime on the system disk first.
    systemctl mask --runtime docker.service docker.socket containerd.service
  fi
  # Use only the signed Amazon Linux repository, retaining its GPG verification.
  dnf --disablerepo='*' --enablerepo=amazonlinux --setopt=gpgcheck=1 -y install docker containerd

  if ! mountpoint -q /var/lib/containerd; then
    require_empty_directory /var/lib/containerd
    install -d -o 0 -g 0 -m 0700 /var/lib/containerd
  fi
  ensure_fstab_entry "$DATA_MOUNT/containerd" /var/lib/containerd none bind,nofail,x-systemd.requires-mounts-for=/srv/maptalk 0
  mountpoint -q /var/lib/containerd || mount /var/lib/containerd
  [[ "$(findmnt -rn -M /var/lib/containerd -o UUID)" == "$uuid" ]] || die 'Containerd is not on the data volume.'
  [[ "$(findmnt -rn -M /var/lib/containerd -o FSROOT)" == /containerd ]] || die 'Unexpected containerd bind mount.'

  WORK_DIR="$(mktemp -d /run/maptalk-bootstrap.XXXXXX)"
  trap 'rm -rf -- "$WORK_DIR"' EXIT
  install -d -o 0 -g 0 -m 0755 /etc/docker /usr/local/lib/docker/cli-plugins \
    /etc/systemd/system/docker.service.d /etc/systemd/system/containerd.service.d
  write_once /etc/docker/daemon.json 0644 <<'JSON'
{
  "data-root": "/srv/maptalk/docker",
  "log-driver": "json-file",
  "log-opts": {"max-size": "10m", "max-file": "3"},
  "builder": {"gc": {"enabled": true, "defaultKeepStorage": "2GB"}}
}
JSON
  install -d -o 0 -g 0 -m 0755 /usr/local/sbin
  write_once /usr/local/sbin/maptalk-require-data-mount 0755 <<GUARD
#!/usr/bin/env bash
set -euo pipefail
[[ "\$(findmnt -rn -M /srv/maptalk -o UUID)" == "$uuid" ]]
[[ "\$(findmnt -rn -M /var/lib/containerd -o UUID)" == "$uuid" ]]
[[ "\$(findmnt -rn -M /var/lib/containerd -o FSROOT)" == /containerd ]]
GUARD
  for current in docker containerd; do
    write_once "/etc/systemd/system/$current.service.d/maptalk-storage.conf" 0644 <<'UNIT'
[Unit]
RequiresMountsFor=/srv/maptalk /var/lib/containerd
BindsTo=srv-maptalk.mount var-lib-containerd.mount
After=srv-maptalk.mount var-lib-containerd.mount
[Service]
ExecStartPre=/usr/local/sbin/maptalk-require-data-mount
UNIT
  done
  install_plugin docker-compose "https://github.com/docker/compose/releases/download/$COMPOSE_VERSION/docker-compose-linux-aarch64" "$COMPOSE_SHA256"
  install_plugin docker-buildx "https://github.com/docker/buildx/releases/download/$BUILDX_VERSION/buildx-$BUILDX_VERSION.linux-arm64" "$BUILDX_SHA256"
  dockerd --validate --config-file=/etc/docker/daemon.json
  /usr/local/sbin/maptalk-require-data-mount
  systemctl daemon-reload
  # Mark only after all configuration and binary verification succeeded, so a
  # retry after service startup does not mistake our runtime for an unrelated one.
  write_once /etc/maptalk/host-bootstrap-version 0600 <<'VERSION'
1
VERSION
  systemctl unmask --runtime docker.service docker.socket containerd.service
  systemctl enable --now amazon-ssm-agent containerd docker
  [[ "$(docker info --format '{{.DockerRootDir}}')" == /srv/maptalk/docker ]] || die 'Docker is using an unexpected storage directory.'
  docker compose version
  docker buildx version
  log 'Host ready. No application or secrets installed. DNS/TLS and acceptance tests are still required.'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
