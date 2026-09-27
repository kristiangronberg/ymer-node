// npm run window -- <name>: ask the running browser service to open an
// interactive window on that storage state. The service opens it, not this
// process, because the service is what must know the name is held. The request
// carries the service's token, read from the same file the service reads.
import { portEnv } from './env.js';
import { defaultTokenFile, readToken } from './token.js';

const name = process.argv[2];

if (!name) {
  console.error('Usage: npm run window -- <storage state name>');
  process.exit(2);
}

let port;
let token;
try {
  port = portEnv('BROWSER_SERVICE_PORT', 8013);
  token = readToken(defaultTokenFile());
} catch (error) {
  console.error(error.message);
  process.exit(1);
}

let response;
try {
  response = await fetch(`http://127.0.0.1:${port}/window`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${token}` },
    body: JSON.stringify({ name }),
  });
} catch {
  console.error(`Nothing answers on http://127.0.0.1:${port}: start the browser service first, with npm start in browser-service/.`);
  process.exit(1);
}

const answer = await response.json();
if (!response.ok) {
  console.error(answer.error);
  process.exit(1);
}
console.log(`An interactive window is open on ${answer.name}. Closing it saves the storage state and releases the name.`);
