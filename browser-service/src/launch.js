// Every browser this service starts comes through here, so a Playwright whose
// browser build was never downloaded refuses with the one instruction that
// fixes it rather than Playwright's own box of text.
export class LaunchError extends Error {
  name = 'LaunchError';
}

export async function launch(browserType, options = {}) {
  try {
    return await browserType.launch(options);
  } catch (error) {
    if (/executable doesn't exist/i.test(error.message)) {
      throw new LaunchError(
        'The browser build this Playwright needs is not downloaded: run npm install in browser-service/, which fetches it.'
      );
    }
    throw error;
  }
}

// The one headless browser every browser call opens its context in. A browser
// that is gone — crashed, killed — is launched again by the next call; calls
// arriving while that launch runs share it rather than launching one each,
// and a launch that fails leaves the next call to try again.
export function browserAccessor(browserType, initial) {
  let current = initial;
  let relaunching = null;
  return async function browser() {
    if (current.isConnected()) return current;
    relaunching ??= launch(browserType)
      .then((launched) => {
        current = launched;
        return launched;
      })
      .finally(() => {
        relaunching = null;
      });
    return relaunching;
  };
}
