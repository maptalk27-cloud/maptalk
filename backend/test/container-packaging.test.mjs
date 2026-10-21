import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { containerConfiguration, checkContainerHealth } from '../scripts/container-healthcheck.mjs';

const environment = {
  NODE_ENV: 'production', MAPTALK_MODE: 'beta',
  MAPTALK_PUBLIC_ORIGIN: 'https://beta.maptalk.app',
  MAPTALK_DOMAIN: 'beta.maptalk.app',
};

async function healthServer(t, handler) {
  const server = createServer(handler);
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => { server.closeAllConnections(); server.close(resolve); }));
  return { ...environment, PORT: String(server.address().port) };
}

test('container configuration requires an explicit, non-placeholder HTTPS domain', () => {
  assert.deepEqual(containerConfiguration(environment), { host: 'beta.maptalk.app', port: 8787 });
  for (const domain of [
    'example.com', 'api.example.org', 'beta.maptalk.example', 'beta.test', 'beta.invalid',
    'localhost', 'api.local', '192.0.2.1', 'your-domain.com', 'changeme.app',
    'bad-.app', '-bad.app', 'beta..app', 'beta.maptalk.app.',
  ]) {
    assert.throws(() => containerConfiguration({
      ...environment, MAPTALK_PUBLIC_ORIGIN: `https://${domain}`, MAPTALK_DOMAIN: domain,
    }), /requires/);
  }
  for (const overrides of [
    { NODE_ENV: 'development' }, { MAPTALK_MODE: 'local' },
    { MAPTALK_DOMAIN: '' },
    { MAPTALK_DOMAIN: 'other.maptalk.app' },
    { MAPTALK_PUBLIC_ORIGIN: 'http://beta.maptalk.app' },
    { MAPTALK_PUBLIC_ORIGIN: 'https://beta.maptalk.app/' },
    { MAPTALK_PUBLIC_ORIGIN: 'https://beta.maptalk.app:8443' },
    { MAPTALK_PUBLIC_ORIGIN: 'https://user:password@beta.maptalk.app' },
    { PORT: '0' }, { PORT: '65536' }, { PORT: '8787.5' }, { PORT: 'not-a-port' },
  ]) assert.throws(() => containerConfiguration({ ...environment, ...overrides }));
});

test('deployment templates agree on the user-owned API hostname without placeholder policy links', async () => {
  const hostTemplate = await readFile(new URL('../deploy/aws/compose.env.example', import.meta.url), 'utf8');
  const appTemplate = await readFile(new URL('../../Config/Backend.local.xcconfig.example', import.meta.url), 'utf8');
  const domain = hostTemplate.match(/^MAPTALK_DOMAIN=(.+)$/m)?.[1].trim();
  const origin = appTemplate.match(/^MAPTALK_API_BASE_URL\s*=\s*(.+)$/m)?.[1].trim().replace('$()', '');
  assert.equal(domain, 'api.maptalkapp.com');
  assert.equal(origin, `https://${domain}`);
  assert.deepEqual(containerConfiguration({
    ...environment, MAPTALK_DOMAIN: domain, MAPTALK_PUBLIC_ORIGIN: origin,
  }), { host: domain, port: 8787 });
  for (const key of ['MAPTALK_PRIVACY_URL', 'MAPTALK_SUPPORT_URL']) {
    const setting = appTemplate.split('\n').find(line => line.startsWith(`${key} =`));
    assert.equal(setting?.split('=').slice(1).join('=').trim(), '');
  }
});

test('container health connects to loopback with the real Host and verifies private-beta', async t => {
  let seen = false;
  const env = await healthServer(t, (request, response) => {
    assert.equal(request.headers.host, environment.MAPTALK_DOMAIN);
    assert.equal(request.url, '/health');
    seen = true;
    response.end(JSON.stringify({ status: 'ok', mode: 'private-beta', apiVersion: 1 }));
  });
  await checkContainerHealth(env);
  assert.equal(seen, true);
});

test('container health rejects local mode, errors, malformed JSON and redirects', async t => {
  for (const [status, body] of [
    [200, { status: 'ok', mode: 'local-development', apiVersion: 1 }],
    [200, { status: 'ok', mode: 'private-beta', apiVersion: 2 }],
    [200, { status: 'error', mode: 'private-beta', apiVersion: 1 }],
    [503, { status: 'ok', mode: 'private-beta', apiVersion: 1 }],
    [302, { status: 'ok', mode: 'private-beta', apiVersion: 1 }],
    [200, 'not-json'], [200, null],
  ]) {
    const env = await healthServer(t, (_request, response) => {
      response.writeHead(status);
      response.end(typeof body === 'string' ? body : JSON.stringify(body));
    });
    await assert.rejects(checkContainerHealth(env), /not a healthy private-beta/);
  }
});

test('container health has a total deadline and bounded response size', async t => {
  const stalled = await healthServer(t, () => {});
  await assert.rejects(checkContainerHealth(stalled, { timeoutMs: 40 }), /timed out/);
  const oversized = await healthServer(t, (_request, response) => response.end('x'.repeat(8192)));
  await assert.rejects(checkContainerHealth(oversized), /response size/);
});

test('configuration-only command rejects placeholders without starting a server', () => {
  const script = fileURLToPath(new URL('../scripts/container-healthcheck.mjs', import.meta.url));
  const accepted = spawnSync(process.execPath, [script, '--check-config'], {
    env: environment, encoding: 'utf8',
  });
  assert.equal(accepted.status, 0, accepted.stderr);
  const rejected = spawnSync(process.execPath, [script, '--check-config'], {
    env: { ...environment, MAPTALK_DOMAIN: 'api.example.com', MAPTALK_PUBLIC_ORIGIN: 'https://api.example.com' },
    encoding: 'utf8',
  });
  assert.equal(rejected.status, 1);
  assert.match(rejected.stderr, /placeholder/);
});

test('Docker context is a narrow allowlist without env, keys, databases or host dependencies', async () => {
  const ignore = await readFile(new URL('../.dockerignore', import.meta.url), 'utf8');
  const patterns = ignore.split('\n').filter(line => line && !line.startsWith('#'));
  assert.deepEqual(patterns, [
    '**', '!package.json', '!package-lock.json', '!src/', '!src/*.mjs', '!src/schema.sql',
    '!scripts/', '!scripts/container-healthcheck.mjs', '!scripts/deployment-preflight.mjs', '!scripts/beta.mjs',
    '!scripts/backup.mjs', '!scripts/encrypted-backup.mjs',
  ]);
  const dockerfile = await readFile(new URL('../Dockerfile', import.meta.url), 'utf8');
  assert.match(dockerfile, /FROM node:24-bookworm-slim AS runtime/);
  assert.match(dockerfile, /apt-get install -y --no-install-recommends ffmpeg/);
  assert.match(dockerfile, /ffmpeg -version >\/dev\/null && ffprobe -version >\/dev\/null/);
  assert.match(dockerfile, /npm ci --omit=dev --include=optional --engine-strict/);
  assert.match(dockerfile, /FROM caddy:2-alpine AS proxy/);
  assert.match(dockerfile, /setcap -r \/usr\/bin\/caddy/);
  assert.match(dockerfile, /^USER 1000:1000$/m);
  assert.match(dockerfile, /deployment-preflight\.mjs && exec node src\/main\.mjs/);
  assert.doesNotMatch(dockerfile, /^COPY\s+\.\s/m);
});

test('Compose isolates a single API and bounds resources, logs and writable storage', async () => {
  const compose = await readFile(new URL('../deploy/aws/compose.yaml', import.meta.url), 'utf8');
  const api = compose.split('\n  api:\n')[1].split('\n  caddy:\n')[0];
  const caddy = compose.split('\n  caddy:\n')[1].split('\nnetworks:\n')[0];
  assert.doesNotMatch(api, /^\s+ports:/m);
  assert.match(api, /container_name: maptalk-beta-api/);
  assert.match(api, /MAPTALK_MODE: beta/);
  assert.match(api, /MAPTALK_DEPLOYMENT_TARGET: aws/);
  assert.match(api, /AWS_REGION: us-east-2/);
  assert.match(api, /AWS_EC2_METADATA_V1_DISABLED: "true"/);
  assert.match(api, /MAPTALK_PUBLIC_ORIGIN: https:\/\/\$\{MAPTALK_DOMAIN:\?/);
  assert.match(api, /MAPTALK_APPLE_PRIVATE_KEY_PATH: \/run\/secrets\/apple_sign_in/);
  assert.match(api, /target: \/var\/lib\/maptalk/);
  assert.match(api, /target: \/var\/backups\/maptalk/);
  for (const service of [api, caddy]) {
    assert.match(service, /user: "1000:1000"/);
    assert.match(service, /read_only: true/);
    assert.match(service, /cap_drop: \[ALL\]/);
    assert.match(service, /no-new-privileges:true/);
    assert.match(service, /mem_limit: \d+m/);
    assert.match(service, /memswap_limit: \d+m/);
    assert.match(service, /cpus: [\d.]+/);
    assert.match(service, /pids_limit: \d+/);
    assert.match(service, /\/tmp:rw,noexec,nosuid,nodev,size=\d+m,mode=1777/);
    assert.match(service, /max-size: 10m/);
    assert.match(service, /max-file: "3"/);
  }
  assert.match(caddy, /condition: service_healthy/);
  assert.match(caddy, /target: proxy/);
  assert.match(caddy, /"80:8080"/);
  assert.match(caddy, /"443:8443"/);
  assert.doesNotMatch(compose, /\/var\/run\/docker\.sock|privileged: true|network_mode: host/);
});

test('Caddy uses real public HTTPS and preserves the host allowlist', async () => {
  const caddy = await readFile(new URL('../deploy/aws/Caddyfile', import.meta.url), 'utf8');
  assert.match(caddy, /https:\/\/\{\$MAPTALK_DOMAIN\} \{/);
  assert.match(caddy, /http_port 8080/);
  assert.match(caddy, /https_port 8443/);
  assert.match(caddy, /admin off/);
  assert.match(caddy, /header_up Host \{http\.request\.hostport\}/);
  assert.match(caddy, /reverse_proxy api:8787/);
  // Video probe/decode/remux/probe has a combined 80-second bound.
  assert.match(caddy, /response_header_timeout 120s/);
  assert.doesNotMatch(caddy, /^\s*(?:tls internal|auto_https off|log)\b/m);
});

test('Compose config parses offline when the Compose CLI is installed', t => {
  const version = spawnSync('docker', ['compose', 'version', '--short'], { encoding: 'utf8' });
  if (version.status !== 0) {
    t.skip('Docker Compose CLI unavailable; no daemon will be started for tests.');
    return;
  }
  const result = spawnSync('docker', [
    'compose', '--env-file', '/dev/null',
    '-f', fileURLToPath(new URL('../deploy/aws/compose.yaml', import.meta.url)),
    'config', '--quiet',
  ], {
    encoding: 'utf8',
    // Inert paths, never an actual credential or database. "config" neither
    // contacts the daemon nor creates these host directories.
    env: {
      ...process.env,
      MAPTALK_DOMAIN: environment.MAPTALK_DOMAIN,
      MAPTALK_ENV_FILE: '/dev/null',
      MAPTALK_DATA_DIRECTORY: '/tmp/maptalk-config-test-data',
      MAPTALK_BACKUP_DIRECTORY_HOST: '/tmp/maptalk-config-test-backups',
      MAPTALK_CADDY_DATA_DIRECTORY: '/tmp/maptalk-config-test-caddy-data',
      MAPTALK_CADDY_CONFIG_DIRECTORY: '/tmp/maptalk-config-test-caddy-config',
      MAPTALK_APPLE_PRIVATE_KEY_HOST_PATH: '/dev/null',
    },
  });
  assert.equal(result.status, 0, result.stderr);
});
