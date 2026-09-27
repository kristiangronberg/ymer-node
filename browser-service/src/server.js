// The browser service's HTTP surface: POST /call runs one browser call, GET
// /status reports what the service measures about itself, and POST /window opens
// an interactive window. It binds loopback, like the node's own /mcp, and
// refuses anything shaped like a request from a web page — an Origin header, a
// body that is not JSON, a Host that is not this machine — so a website open in
// the user's browser cannot post code to it. Every route then asks for the
// token in tokenFile, read afresh on each request, so another program that can
// reach the port cannot run code through it either.
import http from 'node:http';
import { browserCall } from './call.js';
import { StorageStateError } from './storage-states.js';
import { displayPath, readToken, sameToken } from './token.js';
import { WindowError } from './windows.js';

const HOSTS = ['127.0.0.1', 'localhost', 'host.docker.internal'];

export function createServer({ browser, states, windows, playwright, tokenFile }) {
  const server = http.createServer(async (request, response) => {
    const arrived = Date.now();
    const answer = (status, body) => {
      response.writeHead(status, { 'content-type': 'application/json' });
      response.end(JSON.stringify(body));
    };

    try {
      const refusal = refuse(request, server.address().port);
      if (refusal) return answer(refusal.status, { error: refusal.error });
      const unauthorized = checkToken(request, tokenFile);
      if (unauthorized) return answer(401, { error: unauthorized });

      const route = `${request.method} ${request.url}`;
      if (route === 'GET /status') return answer(200, await status(browser, states, windows, playwright));
      if (route === 'POST /call') {
        const call = parseCall(await readJson(request));
        if (typeof call === 'string') return answer(400, { error: call });
        return answer(200, await browserCall(browser, states, windows, call, arrived));
      }
      if (route === 'POST /window') {
        const body = await readJson(request);
        const opened = await windows.open(body?.name);
        return answer(200, { name: opened.name });
      }
      return answer(404, { error: `no route ${route}: POST /call, GET /status and POST /window are served` });
    } catch (error) {
      if (error instanceof SyntaxError) return answer(400, { error: `the body is not JSON: ${error.message}` });
      if (error instanceof StorageStateError) return answer(400, { error: error.message });
      if (error instanceof WindowError) return answer(409, { error: error.message });
      return answer(500, { error: error.message });
    }
  });
  return server;
}

function refuse(request, port) {
  if (request.headers.origin !== undefined) {
    return { status: 403, error: 'refused: a request carrying an Origin header comes from a web page' };
  }
  if (!HOSTS.map((host) => `${host}:${port}`).includes(request.headers.host)) {
    return { status: 403, error: `refused: Host ${request.headers.host} is not this machine at port ${port}` };
  }
  if (request.method === 'POST') {
    const type = (request.headers['content-type'] ?? '').split(';')[0].trim().toLowerCase();
    if (type !== 'application/json') return { status: 415, error: 'refused: the body must be application/json' };
  }
  return null;
}

// The refusal names where the token is and both ways a node reaches it, since
// the service cannot tell a node on this machine from one in a container.
function checkToken(request, tokenFile) {
  const expected = readToken(tokenFile);
  const given = /^Bearer\s+(\S+)\s*$/i.exec(request.headers.authorization ?? '')?.[1];
  if (given !== undefined && sameToken(given, expected)) return null;
  const what = given === undefined ? 'this request carries no token' : "the token this request carries is not this service's";
  return (
    `refused: ${what}. The token is the contents of ${displayPath(tokenFile)}: a node on this machine reads that file, ` +
    'and BROWSER_SERVICE_TOKEN_FILE moves it for both; a node in Docker takes the contents as BROWSER_SERVICE_TOKEN, ' +
    "in the install's .env"
  );
}

async function readJson(request) {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  return JSON.parse(Buffer.concat(chunks).toString('utf8'));
}

function parseCall(body) {
  const plain = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);
  if (!plain(body)) return 'the body must be a JSON object';
  const call = {
    code: body.code,
    args: body.args ?? {},
    storage: body.storage ?? null,
    save_storage: body.save_storage ?? false,
    browser_context: body.browser_context ?? {},
    screenshot: body.screenshot ?? true,
    bound_ms: body.bound_ms,
  };
  if (typeof call.code !== 'string') return 'code must be a string';
  if (!plain(call.args)) return 'args must be an object';
  if (call.storage !== null && typeof call.storage !== 'string') return 'storage must be a string';
  if (typeof call.save_storage !== 'boolean') return 'save_storage must be true or false';
  if (!plain(call.browser_context)) return 'browser_context must be an object';
  if (typeof call.screenshot !== 'boolean') return 'screenshot must be true or false';
  if (!Number.isInteger(call.bound_ms) || call.bound_ms <= 0) return 'bound_ms must be a positive integer';
  return call;
}

async function status(browser, states, windows, playwright) {
  let chromium = null;
  let launch_error = null;
  try {
    chromium = (await browser()).version();
  } catch (error) {
    launch_error = error.message;
  }
  return { playwright, chromium, launch_error, storage_states: states.names(), windows: windows.names() };
}
