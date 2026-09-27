import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { createStorageStates, defaultDir, StorageStateError } from '../src/storage-states.js';

const scratch = () => fs.mkdtempSync(path.join(os.tmpdir(), 'states-'));

test('a state written by name reads back, and an unwritten one reads null', () => {
  const states = createStorageStates(path.join(scratch(), 'states'));
  assert.equal(states.read('crosskey'), null);
  states.write('crosskey', { cookies: [], origins: [] });
  assert.deepEqual(states.read('crosskey'), { cookies: [], origins: [] });
});

test('the directory is made 0700 and each file 0600, with no temporary file left', () => {
  const dir = path.join(scratch(), 'states');
  const states = createStorageStates(dir);
  states.write('crosskey', { cookies: [], origins: [] });
  assert.equal(fs.statSync(dir).mode & 0o777, 0o700);
  assert.equal(fs.statSync(path.join(dir, 'crosskey.json')).mode & 0o777, 0o600);
  assert.deepEqual(fs.readdirSync(dir), ['crosskey.json']);
});

test('names lists the states in order', () => {
  const states = createStorageStates(path.join(scratch(), 'states'));
  assert.deepEqual(states.names(), []);
  states.write('lfb-stage', {});
  states.write('crosskey', {});
  assert.deepEqual(states.names(), ['crosskey', 'lfb-stage']);
});

test('a name with a slash, dots or capitals is refused before any path is built', () => {
  const states = createStorageStates(path.join(scratch(), 'states'));
  for (const name of ['../escape', 'a/b', 'Crosskey', '', 'a.b']) {
    assert.throws(() => states.read(name), StorageStateError);
    assert.throws(() => states.write(name, {}), StorageStateError);
  }
});

test('a file others can read is refused, naming the chmod that fixes it', () => {
  const dir = path.join(scratch(), 'states');
  const states = createStorageStates(dir);
  states.write('crosskey', {});
  fs.chmodSync(path.join(dir, 'crosskey.json'), 0o644);
  assert.throws(() => states.read('crosskey'), /mode 644\): run chmod 600 /);
});

test('a directory others can read is refused, naming the chmod that fixes it', () => {
  const dir = path.join(scratch(), 'states');
  const states = createStorageStates(dir);
  states.write('crosskey', {});
  fs.chmodSync(dir, 0o755);
  assert.throws(() => states.read('crosskey'), /mode 755\): run chmod 700 /);
  assert.throws(() => states.write('crosskey', {}), /run chmod 700 /);
});

test('a file that is not JSON is refused, naming the file', () => {
  const dir = path.join(scratch(), 'states');
  const states = createStorageStates(dir);
  states.write('crosskey', {});
  fs.writeFileSync(path.join(dir, 'crosskey.json'), '{"cookies": [');
  assert.throws(() => states.read('crosskey'), (error) => {
    assert.ok(error instanceof StorageStateError);
    assert.match(error.message, /crosskey\.json is not a storage state/);
    return true;
  });
});

test('the default directory sits under the home directory, and the variable moves it', () => {
  assert.equal(defaultDir({}), path.join(os.homedir(), '.ymer-node', 'storage-states'));
  assert.equal(defaultDir({ BROWSER_SERVICE_STORAGE_DIR: '/elsewhere' }), '/elsewhere');
  assert.equal(defaultDir({ BROWSER_SERVICE_STORAGE_DIR: ' /elsewhere ' }), '/elsewhere');
});

test('a blank or padded-blank variable counts as unset', () => {
  for (const blank of ['', '   ']) {
    assert.equal(defaultDir({ BROWSER_SERVICE_STORAGE_DIR: blank }), path.join(os.homedir(), '.ymer-node', 'storage-states'));
  }
});
