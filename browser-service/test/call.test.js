import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { after, before, test } from 'node:test';
import { chromium } from '@playwright/test';
import { browserCall } from '../src/call.js';
import { launch } from '../src/launch.js';
import { createStorageStates, StorageStateError } from '../src/storage-states.js';

const PNG = Buffer.from([0x89, 0x50, 0x4e, 0x47]);
const noWindows = { holds: () => false, generation: () => 0 };

let browser;
before(async () => {
  browser = await launch(chromium);
});
after(async () => {
  await browser.close();
});

const scratchStates = () => createStorageStates(path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'call-')), 'states'));

const call = (code, fields = {}, { states = scratchStates(), windows = noWindows, started } = {}) =>
  browserCall(
    async () => browser,
    states,
    windows,
    {
      code,
      args: {},
      storage: null,
      save_storage: false,
      browser_context: {},
      screenshot: true,
      bound_ms: 10_000,
      ...fields,
    },
    started
  );

test("answers the code's value with the page's url and title", async () => {
  const answer = await call(
    "async (page, args) => { await page.setContent('<title>Home</title><h1>hi</h1>'); return { heading: await page.textContent('h1'), got: args.n } }",
    { args: { n: 2 } }
  );
  assert.equal(answer.ok, true);
  assert.deepEqual(answer.value, { heading: 'hi', got: 2 });
  assert.equal(answer.url, 'about:blank');
  assert.equal(answer.title, 'Home');
  assert.ok(Number.isInteger(answer.duration_ms));
});

test('a code that returns nothing answers null', async () => {
  const answer = await call('async (page) => {}');
  assert.equal(answer.ok, true);
  assert.equal(answer.value, null);
});

test("a failed expect is thrown, with Playwright's call log and a PNG of the viewport", async () => {
  const answer = await call(
    "async (page, args, expect) => { await page.setContent('<h1>hi</h1>'); await expect(page.getByRole('heading')).toHaveText('nope', { timeout: 300 }) }"
  );
  assert.equal(answer.ok, false);
  assert.equal(answer.error.kind, 'thrown');
  assert.match(answer.error.message, /^expect\(locator\)\.toHaveText\(expected\) failed/);
  assert.ok(answer.error.call_log.some((line) => line.includes("getByRole('heading')")));
  assert.ok(answer.error.call_log.every((line) => !line.includes('\x1b')));
  assert.deepEqual(Buffer.from(answer.error.screenshot, 'base64').subarray(0, 4), PNG);
});

test("the code's own thrown check is thrown too", async () => {
  const answer = await call("async () => { throw new Error('heading was wrong') }");
  assert.equal(answer.error.kind, 'thrown');
  assert.equal(answer.error.name, 'Error');
  assert.equal(answer.error.message, 'heading was wrong');
  assert.deepEqual(answer.error.call_log, []);
});

test('screenshot false takes no picture', async () => {
  const answer = await call("async () => { throw new Error('x') }", { screenshot: false });
  assert.equal(answer.error.screenshot, null);
});

test('text that is not a function is code, and so is a syntax error', async () => {
  assert.equal((await call('42')).error.kind, 'code');
  assert.equal((await call('async (page => {')).error.kind, 'code');
});

test('a handle, a function or a cyclic object is value', async () => {
  await Promise.all(
    [
      "async (page) => { await page.setContent('<h1>hi</h1>'); return await page.$('h1') }",
      'async () => () => 1',
      'async () => { const a = {}; a.self = a; return a }',
    ].map(async (code) => assert.equal((await call(code)).error.kind, 'value'))
  );
});

test('a returned Buffer arrives as its base64 text', async () => {
  const answer = await call("async (page) => { await page.setContent('<h1>hi</h1>'); return await page.screenshot() }");
  assert.deepEqual(Buffer.from(answer.value, 'base64').subarray(0, 4), PNG);
});

test('a call past its bound is timeout, with a picture of where it stood', async () => {
  const answer = await call("async (page) => { await page.setContent('<p>x</p>'); await page.getByText('never').click() }", {
    bound_ms: 300,
  });
  assert.equal(answer.error.kind, 'timeout');
  assert.match(answer.error.message, /300 ms/);
  assert.deepEqual(Buffer.from(answer.error.screenshot, 'base64').subarray(0, 4), PNG);
});

test('browser_context reaches the new context unchanged', async () => {
  const answer = await call('async (page) => page.viewportSize()', { browser_context: { viewport: { width: 500, height: 400 } } });
  assert.deepEqual(answer.value, { width: 500, height: 400 });
});

test('a reading call on an unknown storage state is storage', async () => {
  const answer = await call('async () => 1', { storage: 'nobody' });
  assert.equal(answer.error.kind, 'storage');
  assert.match(answer.error.message, /no storage state is named nobody/);
});

test('a saving call creates the state on success, and the next call reads it', async () => {
  const states = scratchStates();
  const saved = await call(
    "async (page) => { await page.context().addCookies([{ name: 'k', value: 'v', url: 'http://127.0.0.1:9' }]) }",
    { storage: 'crosskey', save_storage: true },
    { states }
  );
  assert.equal(saved.ok, true);
  assert.deepEqual(states.names(), ['crosskey']);
  const read = await call("async (page) => (await page.context().cookies('http://127.0.0.1:9'))[0].value", { storage: 'crosskey' }, { states });
  assert.equal(read.value, 'v');
});

test('a failed saving call saves nothing', async () => {
  const states = scratchStates();
  await call("async () => { throw new Error('x') }", { storage: 'crosskey', save_storage: true }, { states });
  assert.deepEqual(states.names(), []);
});

test('a saving call on a name a window holds is storage, and a reading one proceeds', async () => {
  const states = scratchStates();
  states.write('crosskey', { cookies: [], origins: [] });
  const windows = { holds: (name) => name === 'crosskey', generation: () => 1 };
  const refused = await call('async () => 1', { storage: 'crosskey', save_storage: true }, { states, windows });
  assert.equal(refused.error.kind, 'storage');
  assert.match(refused.error.message, /interactive window is open on crosskey/);
  assert.equal((await call('async () => 1', { storage: 'crosskey' }, { states, windows })).value, 1);
});

test('a bad storage name is storage', async () => {
  assert.equal((await call('async () => 1', { storage: '../x' })).error.kind, 'storage');
});

test('a saving call on a name a window opened on while it ran is storage, and the window keeps its state', async () => {
  const states = scratchStates();
  states.write('crosskey', { cookies: [], origins: [] });
  // The name's generation moves between the call's start and its save, as it
  // does when a window opens on the name — and perhaps closes — mid-call.
  let asked = 0;
  const windows = { holds: () => false, generation: () => asked++ };
  const answer = await call(
    "async (page) => { await page.context().addCookies([{ name: 'k', value: 'v', url: 'http://127.0.0.1:9' }]) }",
    { storage: 'crosskey', save_storage: true },
    { states, windows }
  );
  assert.equal(answer.error.kind, 'storage');
  assert.match(answer.error.message, /window opened on crosskey while this call ran/);
  assert.deepEqual(states.read('crosskey'), { cookies: [], origins: [] });
});

test('a save the storage states refuse is storage, with their instruction', async () => {
  const states = {
    read: () => null,
    write: () => {
      throw new StorageStateError('/states is readable by others (mode 755): run chmod 700 /states');
    },
  };
  const answer = await call('async () => 1', { storage: 'crosskey', save_storage: true }, { states });
  assert.equal(answer.error.kind, 'storage');
  assert.match(answer.error.message, /run chmod 700/);
});

test('a context Playwright will not open is thrown, in the failure shape', async () => {
  const closed = {
    newContext: async () => {
      throw new Error('browser.newContext: Target page, context or browser has been closed');
    },
  };
  const answer = await browserCall(async () => closed, scratchStates(), noWindows, {
    code: 'async () => 1',
    args: {},
    storage: null,
    save_storage: false,
    browser_context: {},
    screenshot: true,
    bound_ms: 10_000,
  });
  assert.equal(answer.ok, false);
  assert.equal(answer.error.kind, 'thrown');
  assert.match(answer.error.message, /has been closed/);
  assert.equal(answer.error.screenshot, null);
});

test('a browser that cannot be launched again is thrown, in the failure shape', async () => {
  const unlaunchable = async () => {
    throw new Error('The browser build this Playwright needs is not downloaded');
  };
  const answer = await browserCall(unlaunchable, scratchStates(), noWindows, {
    code: 'async () => 1',
    args: {},
    storage: null,
    save_storage: false,
    browser_context: {},
    screenshot: true,
    bound_ms: 10_000,
  });
  assert.equal(answer.error.kind, 'thrown');
  assert.match(answer.error.message, /not downloaded/);
});

test('the bound counts from when the request arrived, not from when the call began', async () => {
  const code = 'async () => { await new Promise((done) => setTimeout(done, 800)); return 1 }';
  const answer = await call(code, { bound_ms: 1_500 }, { started: Date.now() - 1_200 });
  assert.equal(answer.error.kind, 'timeout');
});
