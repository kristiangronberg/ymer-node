import assert from 'node:assert/strict';
import { setTimeout as sleep } from 'node:timers/promises';
import { test } from 'node:test';
import { chromium } from '@playwright/test';
import { browserAccessor, launch, LaunchError } from '../src/launch.js';

test('a missing browser build refuses with the npm install instruction', async () => {
  await assert.rejects(launch(chromium, { executablePath: '/nonexistent/chrome' }), (error) => {
    assert.ok(error instanceof LaunchError);
    assert.match(error.message, /run npm install in browser-service\//);
    return true;
  });
});

test('the pinned build launches', async () => {
  const browser = await launch(chromium);
  assert.ok(browser.isConnected());
  await browser.close();
});

// Stand-ins for a browser type and its browsers: no Chromium is started.
const gone = { isConnected: () => false };
const fakeType = (outcomes) => {
  const type = {
    launches: 0,
    async launch() {
      type.launches += 1;
      await sleep(10);
      const outcome = outcomes.shift();
      if (outcome instanceof Error) throw outcome;
      return outcome;
    },
  };
  return type;
};

test('calls meeting a gone browser share one launch of the next', async () => {
  const next = { isConnected: () => true };
  const type = fakeType([next]);
  const browser = browserAccessor(type, gone);
  const answers = await Promise.all([browser(), browser(), browser()]);
  assert.equal(type.launches, 1);
  assert.ok(answers.every((answer) => answer === next));
  assert.equal(await browser(), next);
  assert.equal(type.launches, 1);
});

test('a launch that fails leaves the next call to launch again', async () => {
  const next = { isConnected: () => true };
  const type = fakeType([new Error('no display'), next]);
  const browser = browserAccessor(type, gone);
  await assert.rejects(browser(), /no display/);
  assert.equal(await browser(), next);
  assert.equal(type.launches, 2);
});
