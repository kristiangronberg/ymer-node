// The service's own environment variables, read the way the node reads its
// own: a blank or padded value counts as unset, and a port that is not a whole
// number from 1 to 65535 is refused by the variable's name rather than reaching
// the socket as NaN or 0.
export class EnvError extends Error {
  name = 'EnvError';
}

export function env(name, source = process.env) {
  const value = (source[name] ?? '').trim();
  return value === '' ? null : value;
}

export function portEnv(name, fallback, source = process.env) {
  const value = env(name, source);
  if (value === null) return fallback;
  const port = /^\d+$/.test(value) ? Number(value) : NaN;
  if (!(port >= 1 && port <= 65535)) {
    throw new EnvError(
      `${name} is ${JSON.stringify(value)}, which is not a port: set a whole number from 1 to 65535, or unset it for ${fallback}`
    );
  }
  return port;
}
