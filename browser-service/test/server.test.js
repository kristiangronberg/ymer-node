import assert from 'node:assert/strict';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { after, before, test } from 'node:test';
import { chromium } from '@playwright/test';
import { launch } from '../src/launch.js';
import { createServer } from '../src/server.js';
import { createStorageStates } from '../src/storage-states.js';
import { createWindows } from '../src/windows.js';

let browser;
let server;
let windows;
let port;
let tokenFile;

// Port 0, and a scratch directory for the storage states and the token, so the suite never meets
// a service already serving on 8013, the storage states a person keeps, or their token.
before(async () => {
  browser = await launch(chromium);
  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'server-'));
  const states = createStorageStates(path.join(scratch, 'states'));
  tokenFile = path.join(scratch, 'browser-service-token');
  fs.writeFileSync(tokenFile, 'the-token\n', { mode: 0o600 });
  windows = createWindows({ browserType: chromium, states, headless: true });
  server = createServer({ browser: async () => browser, states, windows, playwright: 'pinned', tokenFile });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  port = server.address().port;
});
after(async () => {
  await windows.closeAll();
  await new Promise((resolve) => server.close(resolve));
  await browser.close();
});

// node:http rather than fetch, so a test can send any Host, Origin and token it likes. The
// token is the service's unless a case replaces it, or removes it with `authorization: undefined`.
const send = (method, route, { body, headers = {} } = {}) =>
  new Promise((resolve, reject) => {
    const all = { host: `127.0.0.1:${port}`, authorization: 'Bearer the-token', ...headers };
    if (all.authorization === undefined) delete all.authorization;
    const request = http.request(
      { host: '127.0.0.1', port, method, path: route, headers: all },
      (response) => {
        const chunks = [];
        response.on('data', (chunk) => chunks.push(chunk));
        response.on('end', () => resolve({ status: response.statusCode, body: JSON.parse(Buffer.concat(chunks)) }));
      }
    );
    request.on('error', reject);
    request.end(body);
  });

const json = { 'content-type': 'application/json' };

test('POST /call answers the browser call', async () => {
  const { status, body } = await send('POST', '/call', { headers: json, body: JSON.stringify({ code: 'async () => 7', bound_ms: 5_000 }) });
  assert.equal(status, 200);
  assert.equal(body.ok, true);
  assert.equal(body.value, 7);
});

test('a call whose fields are wrong is 400, naming the field', async () => {
  const { status, body } = await send('POST', '/call', { headers: json, body: JSON.stringify({ code: 'async () => 7' }) });
  assert.equal(status, 400);
  assert.match(body.error, /bound_ms/);
});

test('a body that is not JSON is 400', async () => {
  const { status } = await send('POST', '/call', { headers: json, body: '{' });
  assert.equal(status, 400);
});

test('a request carrying an Origin header is refused', async () => {
  const headers = { ...json, origin: 'https://example.com' };
  const { status } = await send('POST', '/call', { headers, body: JSON.stringify({ code: 'async () => 7', bound_ms: 5_000 }) });
  assert.equal(status, 403);
});

test('a body that is not application/json is refused', async () => {
  const headers = { 'content-type': 'text/plain' };
  const { status } = await send('POST', '/call', { headers, body: JSON.stringify({ code: 'async () => 7', bound_ms: 5_000 }) });
  assert.equal(status, 415);
});

test('a Host other than this machine at this port is refused, and each of the three names passes', async () => {
  assert.equal((await send('GET', '/status', { headers: { host: `evil.example:${port}` } })).status, 403);
  assert.equal((await send('GET', '/status', { headers: { host: '127.0.0.1:1' } })).status, 403);
  for (const host of ['127.0.0.1', 'localhost', 'host.docker.internal']) {
    assert.equal((await send('GET', '/status', { headers: { host: `${host}:${port}` } })).status, 200);
  }
});

test("a request without the token is refused, naming the token's file and both ways a node reaches it", async () => {
  const { status, body } = await send('GET', '/status', { headers: { authorization: undefined } });
  assert.equal(status, 401);
  assert.match(body.error, /this request carries no token/);
  assert.ok(body.error.includes(`The token is the contents of ${tokenFile}`));
  assert.match(body.error, /BROWSER_SERVICE_TOKEN_FILE/);
  assert.match(body.error, /BROWSER_SERVICE_TOKEN,/);
});

test('a request with another token is refused, on every route', async () => {
  const headers = { ...json, authorization: 'Bearer not-the-token' };
  for (const [method, route, body] of [
    ['GET', '/status'],
    ['POST', '/call', JSON.stringify({ code: 'async () => 7', bound_ms: 5_000 })],
    ['POST', '/window', JSON.stringify({ name: 'crosskey' })],
    ['GET', '/'],
  ]) {
    const answer = await send(method, route, { headers, body });
    assert.equal(answer.status, 401);
    assert.match(answer.body.error, /the token this request carries is not this service's/);
  }
});

test('a request shaped like a web page is refused as one, before any token is asked for', async () => {
  const { status } = await send('GET', '/status', { headers: { origin: 'https://example.com', authorization: undefined } });
  assert.equal(status, 403);
});

test('the token is read from its file on every request', async () => {
  fs.writeFileSync(tokenFile, 'a-new-token\n');
  try {
    assert.equal((await send('GET', '/status')).status, 401);
    assert.equal((await send('GET', '/status', { headers: { authorization: 'Bearer a-new-token' } })).status, 200);
  } finally {
    fs.writeFileSync(tokenFile, 'the-token\n');
  }
});

test('GET /status reports the versions, the storage states and the held names', async () => {
  const { status, body } = await send('GET', '/status');
  assert.equal(status, 200);
  assert.equal(body.playwright, 'pinned');
  assert.equal(body.chromium, browser.version());
  assert.equal(body.launch_error, null);
  assert.deepEqual(body.storage_states, []);
  assert.deepEqual(body.windows, []);
});

test('POST /window opens an interactive window that /status then names', async () => {
  const opened = await send('POST', '/window', { headers: json, body: JSON.stringify({ name: 'crosskey' }) });
  assert.deepEqual(opened, { status: 200, body: { name: 'crosskey' } });
  const again = await send('POST', '/window', { headers: json, body: JSON.stringify({ name: 'crosskey' }) });
  assert.equal(again.status, 409);
  const { body } = await send('GET', '/status');
  assert.deepEqual(body.windows, ['crosskey']);
  assert.deepEqual(body.storage_states, ['crosskey']);
});

test('POST /window refuses a bad name', async () => {
  const { status } = await send('POST', '/window', { headers: json, body: JSON.stringify({ name: 'Bad/Name' }) });
  assert.equal(status, 400);
});

test('an unknown route is 404', async () => {
  assert.equal((await send('GET', '/')).status, 404);
});
