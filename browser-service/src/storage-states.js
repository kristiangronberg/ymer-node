// The storage states the browser service keeps: one Playwright storageState
// JSON file per name, in a directory outside every checkout. The files hold
// live logins, so they follow the node's own rule for its secrets file — the
// directory 0700, each file 0600 and written atomically — and a read refuses a
// file or directory anyone but its owner can read.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { env } from './env.js';

const NAME = /^[a-z0-9-]+$/;

export class StorageStateError extends Error {
  name = 'StorageStateError';
}

export function defaultDir(source = process.env) {
  return env('BROWSER_SERVICE_STORAGE_DIR', source) ?? path.join(os.homedir(), '.ymer-node', 'storage-states');
}

export function createStorageStates(dir) {
  function file(name) {
    if (typeof name !== 'string' || !NAME.test(name)) {
      throw new StorageStateError(
        `${JSON.stringify(name)} is not a storage state name: lowercase letters, digits and hyphens only`
      );
    }
    return path.join(dir, `${name}.json`);
  }

  function checkMode(target, fix) {
    const mode = fs.statSync(target).mode;
    if (mode & 0o077) {
      const octal = (mode & 0o777).toString(8);
      throw new StorageStateError(`${target} is readable by others (mode ${octal}): run chmod ${fix} ${target}`);
    }
  }

  return {
    dir,

    read(name) {
      const target = file(name);
      if (!fs.existsSync(dir)) return null;
      checkMode(dir, '700');
      if (!fs.existsSync(target)) return null;
      checkMode(target, '600');
      const text = fs.readFileSync(target, 'utf8');
      try {
        return JSON.parse(text);
      } catch (error) {
        throw new StorageStateError(`${target} is not a storage state (${error.message}): delete it, and log in again`);
      }
    },

    write(name, state) {
      const target = file(name);
      fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
      checkMode(dir, '700');
      const temporary = `${target}.${randomUUID()}.tmp`;
      fs.writeFileSync(temporary, JSON.stringify(state), { mode: 0o600 });
      fs.renameSync(temporary, target);
    },

    names() {
      if (!fs.existsSync(dir)) return [];
      return fs
        .readdirSync(dir)
        .filter((entry) => entry.endsWith('.json'))
        .map((entry) => entry.slice(0, -'.json'.length))
        .filter((name) => NAME.test(name))
        .sort();
    },
  };
}
