import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const script = fileURLToPath(new URL('../deploy/aws/bootstrap-host.sh', import.meta.url));
// Only isolated functions run under mocked disk commands. Never execute main(),
// mount/format any disk, start Docker, or require Linux/root for these tests.
function bash(body) {
  return spawnSync('bash', ['-c', 'source "$1"\n' + body, '_', script], {
    encoding: 'utf8', env: { ...process.env, BASH_ENV: '' },
  });
}

test('host bootstrap parses as Bash and refuses non-volume input before any host operations', () => {
  const syntax = spawnSync('bash', ['-n', script], { encoding: 'utf8' });
  assert.equal(syntax.status, 0, syntax.stderr);
  for (const value of ['', '/dev/nvme1n1', 'vol-abc', 'vol-0123456789abcdefg', 'vol-12345678; reboot']) {
    const result = bash(`validate_volume_id '${value}'`);
    assert.equal(result.status, 1, value);
    assert.match(result.stderr, /exact EBS volume ID/);
  }
  for (const value of ['vol-1234abcd', 'vol-0123456789abcdef0']) {
    assert.equal(bash(`validate_volume_id '${value}'`).status, 0);
  }
});

test('NVMe data selection follows EBS serial identity, never disk numbering', () => {
  const result = bash(`
lsblk() { printf '/dev/nvme1n1 disk volroot000000000000\n/dev/nvme0n1 disk vol0123456789abcdef0\n'; }
select_data_device vol-0123456789abcdef0`);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout.trim(), '/dev/nvme0n1');
});

test('missing and duplicate EBS matches fail closed', () => {
  for (const entries of ['', '/dev/nvme1n1 disk vol0123456789abcdef0\n/dev/nvme2n1 disk vol0123456789abcdef0']) {
    const result = bash(`lsblk() { printf '%s\\n' '${entries}'; }; select_data_device vol-0123456789abcdef0`);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /not attached|More than one/);
  }
});

const diskMocks = `
is_block_device() { return 0; }
findmnt() { printf '/dev/nvme0n1p1\\n'; }
lsblk() {
  case "$*" in
    '-dn -o MODEL /dev/nvme1n1') printf 'Amazon Elastic Block Store\\n' ;;
    '-dn -o RO /dev/nvme1n1') printf '0\\n' ;;
    '-bdn -o SIZE /dev/nvme1n1') printf '21474836480\\n' ;;
    '-snr -o PATH /dev/nvme0n1p1') printf '/dev/nvme0n1p1\\n/dev/nvme0n1\\n' ;;
    '-nr -o PATH /dev/nvme1n1') printf '/dev/nvme1n1\\n' ;;
    '-nr -o MOUNTPOINTS /dev/nvme1n1') printf '\\n' ;;
    *) return 99 ;;
  esac
}
`;

test('approved 20 GiB whole EBS disk passes validation', () => {
  const result = bash(`${diskMocks}\nvalidate_data_device /dev/nvme1n1`);
  assert.equal(result.status, 0, result.stderr);
});

test('root ancestry, partitions, wrong capacity/model, read-only and other mounts are rejected', () => {
  const cases = [
    ["printf '/dev/nvme0n1p1\\n/dev/nvme0n1\\n'", "printf '/dev/nvme0n1p1\\n/dev/nvme1n1\\n'", /root disk/],
    ["printf '/dev/nvme1n1\\n'", "printf '/dev/nvme1n1\\n/dev/nvme1n1p1\\n'", /Partitioned/],
    ["printf '21474836480\\n'", "printf '10737418240\\n'", /20 GiB/],
    ["printf 'Amazon Elastic Block Store\\n'", "printf 'Amazon EC2 NVMe Instance Storage\\n'", /Amazon EBS/],
    ["printf '0\\n'", "printf '1\\n'", /read-only/],
    ["printf '\\n'", "printf '/another-app\\n'", /mounted elsewhere/],
  ];
  for (const [before, after, error] of cases) {
    const result = bash(`${diskMocks.replace(before, after)}\nvalidate_data_device /dev/nvme1n1`);
    assert.equal(result.status, 1, result.stderr);
    assert.match(result.stderr, error);
  }
});

test('known data and containerd mounts are allowed on a safe rerun', () => {
  const mocks = diskMocks.replace("printf '\\n'", "printf '/srv/maptalk\\n/var/lib/containerd\\n'");
  const result = bash(`${mocks}\nvalidate_data_device /dev/nvme1n1`);
  assert.equal(result.status, 0, result.stderr);
});

test('existing ext4 is preserved even if initialization was explicitly requested', () => {
  const result = bash(`
blkid() { printf ext4; }
wipefs() { printf ext4; }
mkfs.ext4() { printf 'MUST NOT FORMAT'; return 99; }
prepare_filesystem /dev/fake yes`);
  assert.equal(result.status, 0, result.stderr);
  assert.doesNotMatch(result.stdout, /FORMAT/);
});

test('blank disk requires explicit initialization and formatting does not use force', () => {
  const mocks = `
blkid() { return 2; }
wipefs() { return 0; }
lsblk() { return 0; }
mkfs.ext4() { printf 'FORMAT: %s\\n' "$*"; }
`;
  const refused = bash(`${mocks}\nprepare_filesystem /dev/fake no`);
  assert.equal(refused.status, 1);
  assert.match(refused.stderr, /initialize-empty-volume/);
  assert.doesNotMatch(refused.stdout, /FORMAT/);
  const accepted = bash(`${mocks}\nprepare_filesystem /dev/fake yes`);
  assert.equal(accepted.status, 0, accepted.stderr);
  assert.equal(accepted.stdout.trim(), 'FORMAT: -m 0 -L maptalk-data /dev/fake');
});

test('unknown signatures, probe errors and mounted blank disks are never formatted', () => {
  for (const [probe, signature, mount] of [
    ['printf xfs', 'xfs', ''],
    ['printf ext4', 'ext4 gpt', ''],
    ['return 8', '', ''],
    ['return 2', 'gpt', ''],
    ['return 2', '', '/srv/maptalk'],
  ]) {
    const result = bash(`
blkid() { ${probe}; }
wipefs() { printf '%s' '${signature}'; }
lsblk() { printf '%s' '${mount}'; }
mkfs.ext4() { printf 'MUST NOT FORMAT'; }
prepare_filesystem /dev/fake yes`);
    assert.equal(result.status, 1, result.stderr);
    assert.doesNotMatch(result.stdout, /FORMAT/);
  }
});

test('bootstrap pins plugins, preserves existing config, and guards runtime storage at every boot', async () => {
  const source = await readFile(script, 'utf8');
  assert.match(source, /^COMPOSE_SHA256=[a-f0-9]{64}$/m);
  assert.match(source, /^BUILDX_SHA256=[a-f0-9]{64}$/m);
  assert.match(source, /sha256sum --check --status/);
  assert.match(source, /--proto '=https' --proto-redir '=https'/);
  assert.match(source, /--setopt=gpgcheck=1/);
  assert.match(source, /cmp -s "\$candidate" "\$path" \|\| die/);
  assert.match(source, /"data-root": "\/srv\/maptalk\/docker"/);
  assert.match(source, /BindsTo=srv-maptalk\.mount var-lib-containerd\.mount/);
  assert.match(source, /ExecStartPre=\/usr\/local\/sbin\/maptalk-require-data-mount/);
  assert.match(source, /findmnt -rn -M \/srv\/maptalk -o UUID/);
  assert.match(source, /findmnt -rn -M \/var\/lib\/containerd -o FSROOT/);
  assert.match(source, /install -d -o 1000 -g 1000 -m 0700/);
  assert.doesNotMatch(source, /set -[a-z]*x\b|mkfs\.ext4 -F|curl[^\n]*\|\s*(?:ba)?sh/);
});
