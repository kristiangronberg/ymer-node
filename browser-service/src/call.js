// One browser call: the code a script sent runs as `async (page, args, expect)`
// in a fresh browser context, bounded by what the node says is left of its run,
// and the answer is JSON a script can match on — the returned value, or a
// failure of one kind with Playwright's own name, message and call log.
import { expect } from '@playwright/test';
import { StorageStateError } from './storage-states.js';

// How long the failure screenshot and the page's title, taken together, may take
// once the code has stopped. The node keeps a margin under its own deadline
// for this, for closing the context and for the answer's trip back.
const AFTERMATH_MS = 500;

class BoundPassed extends Error {}

class ValueRefused extends Error {}

// `browser` answers the shared headless browser, relaunching it when it is gone;
// `started` is when the request arrived, so the time spent reading it and
// waiting for that relaunch comes out of the code's bound, not the node's margin.
export async function browserCall(browser, states, windows, request, started = Date.now()) {
  const failure = (kind, error, page) => failed(kind, error, page, request.screenshot);

  let code;
  try {
    code = new Function(`return (${request.code});`)();
  } catch (error) {
    return failure('code', error);
  }
  if (typeof code !== 'function') {
    return failure('code', new Error('the code is not a function: send async (page, args, expect) => …'));
  }

  let state = null;
  let generation = null;
  if (request.storage !== null) {
    if (request.save_storage && windows.holds(request.storage)) {
      return failure(
        'storage',
        new Error(
          `an interactive window is open on ${request.storage}, and it owns the name while it is open: ` +
            'this call may read the state but not save it'
        )
      );
    }
    generation = windows.generation(request.storage);
    try {
      state = states.read(request.storage);
    } catch (error) {
      if (error instanceof StorageStateError) return failure('storage', error);
      throw error;
    }
    if (state === null && !request.save_storage) {
      return failure(
        'storage',
        new Error(`no storage state is named ${request.storage}: a call that saves creates it, and so does npm run window`)
      );
    }
  }

  // A context or page Playwright will not open — a browser_context option it
  // rejects, a browser gone under the call, one that cannot be launched again —
  // is a Playwright error like any the code meets, answered in the same shape.
  let context;
  try {
    context = await (await browser()).newContext({ ...request.browser_context, ...(state ? { storageState: state } : {}) });
  } catch (error) {
    return failure('thrown', error);
  }
  try {
    let page;
    try {
      page = await context.newPage();
    } catch (error) {
      return failure('thrown', error);
    }
    let value;
    let timer;
    // The bound counts from the call's start, so opening the context comes out
    // of the code's own time rather than the node's margin.
    const left = Math.max(0, request.bound_ms - (Date.now() - started));
    const bound = new Promise((_resolve, reject) => {
      timer = setTimeout(() => reject(new BoundPassed(`the call's bound of ${request.bound_ms} ms passed`)), left);
    });
    // The code keeps running past the bound until the context closes under it,
    // and its late rejection must not reach Node as an unhandled one.
    const running = Promise.resolve().then(() => code(page, request.args, expect));
    running.catch(() => {});
    try {
      value = await Promise.race([running, bound]);
    } catch (error) {
      return await failure(error instanceof BoundPassed ? 'timeout' : 'thrown', error, page);
    } finally {
      clearTimeout(timer);
    }

    let json;
    try {
      json = toJson(value);
    } catch (error) {
      return await failure('value', error, page);
    }
    if (request.storage !== null && request.save_storage) {
      const refused = await save(states, windows, request.storage, generation, context);
      if (refused) return await failure(refused.kind, refused.error, page);
    }
    return {
      ok: true,
      value: json,
      url: page.url(),
      title: await quick(page.title(), ''),
      duration_ms: Date.now() - started,
    };
  } finally {
    await context.close();
  }
}

// The window check runs again here, after the code, with nothing awaited
// between it and the write: a window opened on the name while the code ran —
// and perhaps closed again — owns what is saved under it now, and this call's
// state is older. A save that cannot happen fails the call, as a refused read
// does, rather than answering a success that saved nothing.
async function save(states, windows, name, generation, context) {
  let snapshot;
  try {
    snapshot = await context.storageState();
  } catch (error) {
    return { kind: 'thrown', error };
  }
  if (windows.generation(name) !== generation) {
    return {
      kind: 'storage',
      error: new Error(
        `an interactive window opened on ${name} while this call ran, and what it saves is newer: ` +
          "this call's state was not saved"
      ),
    };
  }
  try {
    states.write(name, snapshot);
  } catch (error) {
    return { kind: error instanceof StorageStateError ? 'storage' : 'thrown', error };
  }
  return null;
}

// Only JSON survives: a Buffer — `page.screenshot()` — becomes its base64 text,
// and a function, a Playwright handle or any other non-plain object is refused
// rather than serialised as something the script never returned.
function toJson(value) {
  if (value === undefined) return null;
  const text = JSON.stringify(value, function (key, serialised) {
    const raw = this[key];
    if (Buffer.isBuffer(raw)) return raw.toString('base64');
    if (typeof raw === 'function' || typeof raw === 'symbol') {
      throw new ValueRefused(`the code returned a ${typeof raw}, which does not survive JSON`);
    }
    if (raw !== null && typeof raw === 'object' && !Array.isArray(raw) && !(raw instanceof Date)) {
      const prototype = Object.getPrototypeOf(raw);
      if (prototype !== Object.prototype && prototype !== null) {
        throw new ValueRefused(`the code returned a ${raw.constructor?.name ?? 'non-plain'} object, which does not survive JSON`);
      }
    }
    return serialised;
  });
  return JSON.parse(text);
}

async function failed(kind, error, page, screenshot) {
  const { message, callLog } = split(error);
  const pictured = page && screenshot && (kind === 'thrown' || kind === 'timeout');
  // Both at once, so the two together stay inside one AFTERMATH_MS.
  const [shot, title] = await Promise.all([
    pictured ? quick(page.screenshot(), null) : null,
    page ? quick(page.title(), null) : null,
  ]);
  return {
    ok: false,
    error: {
      kind,
      name: error?.name ?? 'Error',
      message,
      call_log: callLog,
      url: page ? page.url() : null,
      title,
      screenshot: shot ? shot.toString('base64') : null,
    },
  };
}

// Playwright appends its call log to the message, coloured for a terminal.
function split(error) {
  const text = String(error?.message ?? error).replace(/\x1b\[[0-9;]*m/g, '');
  const [message, log = ''] = text.split('\nCall log:\n');
  const callLog = log
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => line !== '');
  return { message: message.trim(), callLog };
}

async function quick(promise, fallback) {
  let timer;
  const late = new Promise((resolve) => {
    timer = setTimeout(() => resolve(fallback), AFTERMATH_MS);
  });
  try {
    return await Promise.race([promise.catch(() => fallback), late]);
  } finally {
    clearTimeout(timer);
  }
}
