// The browser service's token: a random value in a file only its owner can
// read, which every request must carry as Authorization: Bearer. A browser
// call's code runs in this process with the user's privileges, and the
// loopback bind does not keep other programs out — every container on a
// Docker host reaches the service through host.docker.internal, as the node's
// image does — so the token is what does. The file is created if it is
// missing, by whichever process needs it first: this service at its start,
// npm run window, or a node on the same machine.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createHash, randomBytes, randomUUID, timingSafeEqual } from 'node:crypto';
import { env } from './env.js';

export class TokenError extends Error {
  name = 'TokenError';
}

export function defaultTokenFile(source = process.env) {
  return env('BROWSER_SERVICE_TOKEN_FILE', source) ?? path.join(os.homedir(), '.ymer-node', 'browser-service-token');
}

// The file as a refusal names it: under the home directory it reads ~/…, so a
// caller the service refuses learns where the token is without learning whose
// home directory it is in.
export function displayPath(file) {
  const home = os.homedir();
  return file.startsWith(home + path.sep) ? `~${file.slice(home.length)}` : file;
}

// Written whole to a temporary file and linked into place, so a reader never
// meets a half-written token, and a process that loses the race to create it
// reads the winner's rather than replacing it. The temporary file's name is
// random, so two processes creating the file at once never share it.
function create(file) {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o700 });
  const temporary = `${file}.${randomUUID()}.tmp`;
  fs.writeFileSync(temporary, `${randomBytes(32).toString('base64url')}\n`, { mode: 0o600 });
  try {
    fs.linkSync(temporary, file);
  } catch (error) {
    if (error.code !== 'EEXIST') throw error;
  } finally {
    fs.rmSync(temporary, { force: true });
  }
}

export function readToken(file) {
  if (!fs.existsSync(file)) create(file);
  const mode = fs.statSync(file).mode;
  const shown = displayPath(file);
  if (mode & 0o077) {
    const octal = (mode & 0o777).toString(8);
    throw new TokenError(`${shown} is readable by others (mode ${octal}): run chmod 600 ${shown}`);
  }
  const token = fs.readFileSync(file, 'utf8').trim();
  if (token === '') throw new TokenError(`${shown} holds no token: delete it, and the next start writes a new one`);
  return token;
}

// Compared as digests, which are always the same length, so the comparison
// takes the same time whatever the request sent.
export function sameToken(given, expected) {
  const digest = (value) => createHash('sha256').update(value).digest();
  return timingSafeEqual(digest(given), digest(expected));
}
