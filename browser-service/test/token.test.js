import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { defaultTokenFile, displayPath, readToken, sameToken, TokenError } from '../src/token.js';

const scratch = () => fs.mkdtempSync(path.join(os.tmpdir(), 'token-'));

test('a missing file is created 0600, in a directory created 0700, and read back the same', () => {
  const file = path.join(scratch(), 'nested', 'browser-service-token');
  const token = readToken(file);
  assert.match(token, /^[A-Za-z0-9_-]{43}$/);
  assert.equal(fs.statSync(file).mode & 0o777, 0o600);
  assert.equal(fs.statSync(path.dirname(file)).mode & 0o777, 0o700);
  assert.equal(readToken(file), token);
  assert.deepEqual(fs.readdirSync(path.dirname(file)), ['browser-service-token']);
});

test("a file another process wrote is read, not replaced, and its line's padding is dropped", () => {
  const file = path.join(scratch(), 'browser-service-token');
  fs.writeFileSync(file, '  written-elsewhere\n', { mode: 0o600 });
  assert.equal(readToken(file), 'written-elsewhere');
  assert.equal(fs.readFileSync(file, 'utf8'), '  written-elsewhere\n');
});

test('a file anyone else can read is refused, naming the chmod', () => {
  const file = path.join(scratch(), 'browser-service-token');
  fs.writeFileSync(file, 'abc\n', { mode: 0o600 });
  fs.chmodSync(file, 0o644);
  assert.throws(() => readToken(file), (error) => {
    assert.ok(error instanceof TokenError);
    assert.match(error.message, /readable by others \(mode 644\): run chmod 600 /);
    return true;
  });
});

test('an empty file is refused, naming the fix', () => {
  const file = path.join(scratch(), 'browser-service-token');
  fs.writeFileSync(file, '\n', { mode: 0o600 });
  assert.throws(() => readToken(file), /holds no token: delete it/);
});

test('the file is under the home directory unless BROWSER_SERVICE_TOKEN_FILE moves it, blank counting as unset, and shown from ~ there', () => {
  const home = path.join(os.homedir(), '.ymer-node', 'browser-service-token');
  assert.equal(defaultTokenFile({}), home);
  assert.equal(defaultTokenFile({ BROWSER_SERVICE_TOKEN_FILE: '  ' }), home);
  assert.equal(defaultTokenFile({ BROWSER_SERVICE_TOKEN_FILE: '/app/data/token' }), '/app/data/token');
  assert.equal(displayPath(home), '~/.ymer-node/browser-service-token');
  assert.equal(displayPath('/app/data/token'), '/app/data/token');
  assert.equal(displayPath(`${os.homedir()}-elsewhere/token`), `${os.homedir()}-elsewhere/token`);
});

test('tokens compare equal only when they are the same, whatever their lengths', () => {
  assert.equal(sameToken('abc', 'abc'), true);
  assert.equal(sameToken('abd', 'abc'), false);
  assert.equal(sameToken('ab', 'abc'), false);
  assert.equal(sameToken('', 'abc'), false);
});
