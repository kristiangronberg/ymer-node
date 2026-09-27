// npm start: launch the headless browser every browser call opens its context
// in, and serve on 127.0.0.1. Refuses to start — with the instruction that
// fixes it — when BROWSER_SERVICE_PORT is not a port, the token's file is one
// others can read, the pinned Playwright's browser build is missing, or the
// port is taken, so a service that is listening can launch a browser. Writes
// the token's file first when it is missing.
import { createRequire } from 'node:module';
import { chromium } from '@playwright/test';
import { EnvError, portEnv } from './env.js';
import { browserAccessor, launch, LaunchError } from './launch.js';
import { createServer } from './server.js';
import { createStorageStates, defaultDir } from './storage-states.js';
import { defaultTokenFile, readToken, TokenError } from './token.js';
import { createWindows } from './windows.js';

let port;
const tokenFile = defaultTokenFile();
try {
  port = portEnv('BROWSER_SERVICE_PORT', 8013);
  readToken(tokenFile);
} catch (error) {
  console.error(error instanceof EnvError || error instanceof TokenError ? error.message : error);
  process.exit(1);
}
const playwright = createRequire(import.meta.url)('@playwright/test/package.json').version;
const states = createStorageStates(defaultDir());
const windows = createWindows({ browserType: chromium, states });

let headless;
try {
  headless = await launch(chromium);
} catch (error) {
  console.error(error instanceof LaunchError ? error.message : error);
  process.exit(1);
}

const browser = browserAccessor(chromium, headless);

const server = createServer({ browser, states, windows, playwright, tokenFile });
server.on('error', (error) => {
  console.error(
    error.code === 'EADDRINUSE'
      ? `Something already answers on port ${port}: stop it, or move this service with BROWSER_SERVICE_PORT.`
      : error
  );
  process.exit(1);
});
server.listen(port, '127.0.0.1', () => {
  const bound = server.address().port;
  console.log(
    `The browser service answers on http://127.0.0.1:${bound} — Playwright ${playwright}, storage states in ${states.dir}, its token in ${tokenFile}`
  );
});

const stop = async () => {
  await windows.closeAll();
  process.exit(0);
};
process.on('SIGINT', stop);
process.on('SIGTERM', stop);
