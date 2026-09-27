// Interactive windows: a headed Chromium on a storage state, for a person to
// explore, work and log in while scheduled scripts reuse the same login. The
// window owns its name while it is open — a browser call may read the state but
// not save over it — and writes the state on a timer and when its last page
// closes. A window whose browser dies instead keeps its last timed write.
import { launch } from './launch.js';

export const SAVE_EVERY_MS = 60_000;

export class WindowError extends Error {
  name = 'WindowError';
}

export function createWindows({ browserType, states, headless = false, saveEveryMs = SAVE_EVERY_MS }) {
  const open = new Map();
  const generations = new Map();

  // Releases the name only for the window that holds it now, so a window's
  // late close or crash never releases another window's hold.
  function release(name, entry) {
    if (open.get(name) !== entry) return;
    clearInterval(entry.timer);
    open.delete(name);
  }

  async function save(name, context) {
    let state;
    try {
      state = await context.storageState();
    } catch {
      return; // The context is gone with its browser: the last write stands.
    }
    try {
      states.write(name, state);
    } catch (error) {
      // Reported, never thrown on: the timer and the page's close event do not
      // wait for this, and a rejection nobody handles would stop the service.
      console.error(`The interactive window on ${name} could not save its storage state: ${error.message}`);
    }
  }

  return {
    holds(name) {
      return open.has(name);
    },

    // Moves each time a window opens on the name, so a browser call can tell,
    // just before it saves, whether a window has held the name since it began.
    generation(name) {
      return generations.get(name) ?? 0;
    },

    names() {
      return [...open.keys()].sort();
    },

    async open(name) {
      if (open.has(name)) throw new WindowError(`an interactive window is already open on ${name}`);
      // Held from here, before the first await, so a second open on the name —
      // or a browser call about to save under it — sees the hold at once.
      const entry = {};
      const previous = generations.get(name) ?? 0;
      open.set(name, entry);
      generations.set(name, previous + 1);
      try {
        const state = states.read(name);
        entry.browser = await launch(browserType, { headless });
        const context = await entry.browser.newContext({ viewport: null, ...(state ? { storageState: state } : {}) });
        const page = await context.newPage();
        entry.timer = setInterval(() => save(name, context), saveEveryMs);

        const closeWhenEmpty = async () => {
          if (context.pages().length > 0 || open.get(name) !== entry) return;
          await save(name, context);
          release(name, entry);
          await entry.browser.close();
        };
        context.on('page', (added) => added.on('close', closeWhenEmpty));
        page.on('close', closeWhenEmpty);
        entry.browser.on('disconnected', () => release(name, entry));

        if (!state) states.write(name, await context.storageState());
        return { name, page };
      } catch (error) {
        // No window ever held the name, so a call that began before this open
        // may still save: the generation goes back to what it read. The name
        // was held throughout, so nothing else moved it meanwhile.
        generations.set(name, previous);
        release(name, entry);
        if (entry.browser) await entry.browser.close().catch(() => {});
        throw error;
      }
    },

    async closeAll() {
      await Promise.all(
        [...open.entries()].map(async ([name, entry]) => {
          const [context] = entry.browser ? entry.browser.contexts() : [];
          if (context) await save(name, context);
          release(name, entry);
          if (entry.browser) await entry.browser.close();
        })
      );
    },
  };
}
