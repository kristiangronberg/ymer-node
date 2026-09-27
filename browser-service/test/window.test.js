import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import http from 'node:http';
import { test } from 'node:test';

const script = fileURLToPath(new URL('../src/window.js', import.meta.url));
const main = fileURLToPath(new URL('../src/main.js', import.meta.url));

// Every run reads its token from a scratch file, never the one in the home directory.
const tokenFile = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'window-')), 'browser-service-token');
fs.writeFileSync(tokenFile, 'the-token\n', { mode: 0o600 });

const runFile = (file, args, env = {}) =>
  new Promise((resolve) => {
    const all = { ...process.env, BROWSER_SERVICE_TOKEN_FILE: tokenFile, ...env };
    execFile(process.execPath, [file, ...args], { env: all }, (error, stdout, stderr) =>
      resolve({ code: error ? error.code : 0, stdout, stderr })
    );
  });

const run = (args, env = {}) => runFile(script, args, env);

// A port nothing listens on: bind one, note it, close it.
const freePort = () =>
  new Promise((resolve) => {
    const probe = http.createServer().listen(0, '127.0.0.1', () => {
      const { port } = probe.address();
      probe.close(() => resolve(port));
    });
  });

test('with no name it prints the usage, at status 2', async () => {
  const { code, stderr } = await run([]);
  assert.equal(code, 2);
  assert.match(stderr, /npm run window -- <storage state name>/);
});

test('with no service answering it names npm start, at status 1', async () => {
  const { code, stderr } = await run(['crosskey'], { BROWSER_SERVICE_PORT: String(await freePort()) });
  assert.equal(code, 1);
  assert.match(stderr, /start the browser service first, with npm start in browser-service\//);
});

test('a port variable that is not a port is refused by name, at status 1', async () => {
  const { code, stderr } = await run(['crosskey'], { BROWSER_SERVICE_PORT: 'abc' });
  assert.equal(code, 1);
  assert.match(stderr, /BROWSER_SERVICE_PORT is "abc", which is not a port/);
});

// Before any browser launches: the refusal comes first, so this starts no Chromium.
test('npm start refuses a port variable that is not a port, by name', async () => {
  const { code, stderr } = await runFile(main, [], { BROWSER_SERVICE_PORT: '0' });
  assert.equal(code, 1);
  assert.match(stderr, /BROWSER_SERVICE_PORT is "0", which is not a port/);
});

// Also before any browser launches, and before anything listens.
test('npm start refuses a token file others can read, naming the chmod', async () => {
  const readable = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'window-')), 'browser-service-token');
  fs.writeFileSync(readable, 'the-token\n', { mode: 0o600 });
  fs.chmodSync(readable, 0o644);
  const { code, stderr } = await runFile(main, [], { BROWSER_SERVICE_TOKEN_FILE: readable });
  assert.equal(code, 1);
  assert.match(stderr, /is readable by others \(mode 644\): run chmod 600 /);
});

test("it posts the name as JSON with the service's token, and passes the service's refusal on", async () => {
  const seen = [];
  const service = http.createServer((request, response) => {
    const chunks = [];
    request.on('data', (chunk) => chunks.push(chunk));
    request.on('end', () => {
      seen.push({ headers: request.headers, body: JSON.parse(Buffer.concat(chunks)) });
      response.writeHead(409, { 'content-type': 'application/json' });
      response.end(JSON.stringify({ error: 'an interactive window is already open on crosskey' }));
    });
  });
  await new Promise((resolve) => service.listen(0, '127.0.0.1', resolve));
  const { port } = service.address();
  const { code, stderr } = await run(['crosskey'], { BROWSER_SERVICE_PORT: String(port) });
  service.close();
  assert.equal(code, 1);
  assert.match(stderr, /already open on crosskey/);
  assert.deepEqual(seen[0].body, { name: 'crosskey' });
  assert.equal(seen[0].headers.host, `127.0.0.1:${port}`);
  assert.equal(seen[0].headers.origin, undefined);
  assert.equal(seen[0].headers.authorization, 'Bearer the-token');
});
