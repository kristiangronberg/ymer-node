import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { test } from 'node:test';
import { chromium } from '@playwright/test';
import { createStorageStates } from '../src/storage-states.js';
import { createWindows, WindowError } from '../src/windows.js';

// Headless, so the suite opens no window on the desktop; the lifecycle is the same.
const setup = (saveEveryMs) => {
  const states = createStorageStates(path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'windows-')), 'states'));
  return { states, windows: createWindows({ browserType: chromium, states, headless: true, saveEveryMs }) };
};

const cookie = (page) => page.context().addCookies([{ name: 'k', value: 'v', url: 'http://127.0.0.1:9' }]);

test('a new name is created, held while open, and a second window on it is refused', async () => {
  const { states, windows } = setup();
  await windows.open('crosskey');
  assert.deepEqual(states.names(), ['crosskey']);
  assert.equal(windows.holds('crosskey'), true);
  assert.deepEqual(windows.names(), ['crosskey']);
  await assert.rejects(windows.open('crosskey'), WindowError);
  await windows.closeAll();
});

test('closing the last page writes the state and releases the name', async () => {
  const { states, windows } = setup();
  const { page } = await windows.open('crosskey');
  await cookie(page);
  await page.close();
  await sleep(200);
  assert.equal(windows.holds('crosskey'), false);
  assert.equal(states.read('crosskey').cookies[0].value, 'v');
});

test('the timer writes the state while the window stays open', async () => {
  const { states, windows } = setup(50);
  const { page } = await windows.open('crosskey');
  await cookie(page);
  await sleep(300);
  assert.equal(states.read('crosskey').cookies[0].value, 'v');
  await windows.closeAll();
});

test('a window whose browser dies releases the name and keeps the last write', async () => {
  const { states, windows } = setup();
  const { page } = await windows.open('crosskey');
  await cookie(page);
  await page.context().browser().close();
  await sleep(200);
  assert.equal(windows.holds('crosskey'), false);
  assert.deepEqual(states.read('crosskey').cookies, []);
});

test('the name is held from the moment open is called, and its generation moves', () => {
  const { windows } = setup();
  assert.equal(windows.generation('crosskey'), 0);
  const opening = windows.open('crosskey');
  assert.equal(windows.holds('crosskey'), true);
  assert.equal(windows.generation('crosskey'), 1);
  return opening.then(() => windows.closeAll());
});

test('two opens on one name at once: one window opens, the other is refused', async () => {
  const { windows } = setup();
  const results = await Promise.allSettled([windows.open('crosskey'), windows.open('crosskey')]);
  assert.equal(results.filter((result) => result.status === 'fulfilled').length, 1);
  assert.equal(results.filter((result) => result.status === 'rejected' && result.reason instanceof WindowError).length, 1);
  assert.deepEqual(windows.names(), ['crosskey']);
  await windows.closeAll();
  assert.equal(windows.holds('crosskey'), false);
});

test('a window that fails to open leaves the name free and its generation where it was', async () => {
  const states = {
    read: () => {
      throw new Error('unreadable');
    },
  };
  const windows = createWindows({ browserType: chromium, states, headless: true });
  await assert.rejects(windows.open('crosskey'), /unreadable/);
  assert.equal(windows.holds('crosskey'), false);
  assert.equal(windows.generation('crosskey'), 0);
});
