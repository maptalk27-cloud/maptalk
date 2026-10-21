import assert from 'node:assert/strict';
import { randomBytes, randomUUID } from 'node:crypto';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createBackend } from '../src/server.mjs';
import { backupDatabase } from '../src/backup.mjs';

const directory = await mkdtemp(join(tmpdir(), 'maptalk-demo-'));
const databasePath = join(directory, 'maptalk.sqlite');
const backupPath = join(directory, 'restored.sqlite');
const password = randomBytes(24).toString('base64url');
const photo = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jS1cAAAAASUVORK5CYII=', 'base64');
let backend = createBackend({ databasePath });
let url;

async function call(path, { token, method = 'GET', json, bytes, expected = 200 } = {}) {
  const response = await fetch(`${url}${path}`, {
    method,
    headers: {
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...(json ? { 'Content-Type': 'application/json' } : {}),
      ...(bytes ? { 'Content-Type': 'image/png' } : {}),
    },
    body: json ? JSON.stringify(json) : bytes,
  });
  assert.equal(response.status, expected, `${method} ${path}`);
  return response.status === 204 ? null : response.json();
}

try {
  ({ url } = await backend.listen());
  const alice = await call('/v1/auth/register', { method: 'POST', json: { handle: 'alice', password }, expected: 201 });
  const bob = await call('/v1/auth/register', { method: 'POST', json: { handle: 'bob', password }, expected: 201 });
  assert.notEqual(alice.user.id, bob.user.id);
  console.log('PASS 两个独立账号已创建，没有预设用户。');

  const privatePhoto = await call('/v1/media', { method: 'POST', token: alice.token, bytes: photo, expected: 201 });
  const publicPhoto = await call('/v1/media', { method: 'POST', token: alice.token, bytes: photo, expected: 201 });
  const location = { latitude: 37.3688, longitude: -122.0363 };
  const privateRecord = await call('/v1/memories', {
    method: 'POST', token: alice.token, expected: 201,
    json: { id: randomUUID(), kind: 'poi', visibility: 'private', location,
      place: { name: 'Sunnyvale test café', category: 'coffee' }, mediaIds: [privatePhoto.id] },
  });
  const publicRecord = await call('/v1/memories', {
    method: 'POST', token: alice.token, expected: 201,
    json: { id: randomUUID(), kind: 'poi', visibility: 'public', location,
      placeId: privateRecord.place.id, mediaIds: [publicPhoto.id] },
  });
  const feed = await call('/v1/feed', { token: bob.token });
  assert.deepEqual(feed.items.map(item => item.id), [publicRecord.id]);
  await call(`/v1/memories/${privateRecord.id}`, { token: bob.token, expected: 404 });
  await call(privatePhoto.path, { token: bob.token, expected: 404 });
  const image = await fetch(`${url}${publicPhoto.path}`, { headers: { Authorization: `Bearer ${bob.token}` } });
  assert.equal(image.status, 200);
  assert.deepEqual(Buffer.from(await image.arrayBuffer()), photo);
  console.log('PASS 同地点先私密、后公开：朋友只看得到公开记录和对应照片。');

  await backupDatabase(databasePath, backupPath);
  await backend.close();
  backend = createBackend({ databasePath });
  ({ url } = await backend.listen());
  const login = await call('/v1/auth/login', { method: 'POST', json: { handle: 'alice', password } });
  const archive = await call('/v1/me/memories', { token: login.token });
  assert.equal(archive.items.length, 2);
  await call(privatePhoto.path, { token: bob.token, expected: 404 });
  console.log('PASS 服务关闭再启动：账号、会话、记录和隐私设置仍保留。');

  await backend.close();
  backend = createBackend({ databasePath: backupPath });
  ({ url } = await backend.listen());
  assert.equal((await call('/v1/me/memories', { token: alice.token })).items.length, 2);
  await call(privatePhoto.path, { token: bob.token, expected: 404 });
  const restored = await fetch(`${url}${privatePhoto.path}`, { headers: { Authorization: `Bearer ${alice.token}` } });
  assert.equal(restored.status, 200);
  assert.deepEqual(Buffer.from(await restored.arrayBuffer()), photo);
  console.log('PASS 从独立备份恢复：照片和记录可读，私密照片仍不能被其他账号访问。');
  console.log('完成：这是本机真实 HTTP 测试，不代表 iPhone App 已接入或云端已部署。');
} finally {
  await backend.close();
  await rm(directory, { recursive: true, force: true });
}
