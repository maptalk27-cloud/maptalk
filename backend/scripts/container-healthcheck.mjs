import { request } from 'node:http';
import { isIP } from 'node:net';
import { pathToFileURL } from 'node:url';

// This checks syntax, not domain ownership, DNS, TLS issuance, Apple
// configuration, restore success, spending limits, or AWS readiness.
export function containerConfiguration(env = process.env) {
  if (env.NODE_ENV !== 'production' || env.MAPTALK_MODE !== 'beta') {
    throw new Error('Container requires NODE_ENV=production and MAPTALK_MODE=beta.');
  }
  let origin;
  try { origin = new URL(env.MAPTALK_PUBLIC_ORIGIN); } catch {
    throw new Error('Container requires a canonical public HTTPS origin.');
  }
  const hostname = origin.hostname;
  const labels = hostname.split('.');
  const reserved = /(?:^|\.)(?:localhost|local|test|invalid|example|internal|lan|home|corp)$/i;
  const documentationDomain = /(?:^|\.)example\.(?:com|net|org)$/i;
  const placeholder = /(?:^|[.-])(?:placeholder|changeme|change-me|yourdomain|your-domain|replace-me)(?:[.-]|$)/i;
  if (origin.protocol !== 'https:' || origin.origin !== env.MAPTALK_PUBLIC_ORIGIN
    || origin.username || origin.password || origin.pathname !== '/' || origin.search || origin.hash || origin.port
    || isIP(hostname) || hostname.length > 253 || labels.length < 2
    || labels.some(label => !/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/i.test(label))
    || !/^[a-z][a-z0-9-]+$/i.test(labels.at(-1))
    || reserved.test(hostname) || documentationDomain.test(hostname) || placeholder.test(hostname)) {
    throw new Error('Container requires a real public DNS hostname, not an IP, local, or placeholder domain.');
  }
  if (env.MAPTALK_DOMAIN !== hostname) {
    throw new Error('Set MAPTALK_DOMAIN to the same real hostname as MAPTALK_PUBLIC_ORIGIN.');
  }
  const port = Number(env.PORT ?? 8787);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('PORT must be 1–65535.');
  return { host: origin.host, port };
}

export async function checkContainerHealth(env = process.env, { timeoutMs = 3000 } = {}) {
  const configuration = containerConfiguration(env);
  return new Promise((resolve, reject) => {
    let settled = false;
    let timer;
    function finish(error) {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (error) reject(error);
      else resolve();
    }
    // Connect locally, but send the configured public Host. A loopback Host
    // would correctly be rejected by the beta API's host allowlist.
    const req = request({
      hostname: '127.0.0.1', port: configuration.port, path: '/health',
      method: 'GET', headers: { Host: configuration.host }, agent: false,
    }, response => {
      let body = '';
      response.setEncoding('utf8');
      response.on('data', chunk => {
        body += chunk;
        if (body.length > 4096) {
          const error = new Error('Unexpected health response size.');
          finish(error);
          req.destroy(error);
        }
      });
      response.on('error', finish);
      response.on('end', () => {
        try {
          const health = JSON.parse(body);
          if (response.statusCode !== 200 || health.status !== 'ok'
            || health.mode !== 'private-beta' || health.apiVersion !== 1) {
            throw new Error('Backend is not a healthy private-beta API.');
          }
          finish();
        } catch {
          finish(new Error('Backend is not a healthy private-beta API.'));
        }
      });
    });
    req.on('error', finish);
    // A total deadline also stops a peer that continuously trickles a response.
    timer = setTimeout(() => req.destroy(new Error('Backend health check timed out.')), timeoutMs);
    req.end();
  });
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  try {
    if (process.argv[2] === '--check-config') containerConfiguration();
    else if (process.argv.length === 2) await checkContainerHealth();
    else throw new Error('Use no arguments or --check-config.');
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
