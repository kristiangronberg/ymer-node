# Ymer Node

Ymer Node is the local half of Ymer: a headless MCP server you run on your own
machine, giving an LLM that works with you capability that has to live where you
are. Today that is a notebook — a private SQL store with vector search, which the
LLM creates its own tables in — and a registry of references to where knowledge
lives, with a cache of what they say. None of it leaves this machine.

The other half is ymer, the hosted side, which holds the tasks, projects and
documents any client can reach from anywhere. Neither replaces the other, and the
split is deliberate: things worth having on every device belong there, and things
that belong to this machine belong here. A node keeps working whether or not
anything else is reachable.

## Requirements are real

- **Docker**, to run the image — or **Elixir and Erlang** to run from source.
  `mise.toml` pins the versions this repo is developed against.
- **A directory for the install.** The node writes its databases and its backups
  there, beside the compose file, and creates a files directory your scripts
  read and write; the files there are yours. Only `notebook.db` is worth
  keeping; everything else the node holds can be rebuilt.

## Running it

Build the image in this checkout:

```sh
mise exec -- mix deps.get
mise exec -- mix ymer_node.build
```

Then make the install: copy `docker-compose.yml` into the directory you have
chosen for it, and bring the node up there:

```sh
docker compose up -d
```

The build task tags the image it produces `ymer-node:<version>`,
`ymer-node:latest` and `ymer-node:<revision>` — the last naming the commit it
was built from. The compose file runs `ymer-node:latest` and never builds it,
so an `up` here cannot pick up code you did not build; what does move that tag
is written where the tag is moved, in `Mix.Tasks.YmerNode.Build`'s moduledoc.
Without Elixir, `docker build -t ymer-node:latest .` builds the same image
minus the version and revision tags.

To deploy new code, run `mise exec -- mix ymer_node.deploy` with the install's
container stopped (`docker compose stop` there; the deploy refuses while it
runs). It builds this checkout's committed `main`, carries the compose file
into the install, recreates the container on the new image, and does not
report success until the node answers on that image. The store is untouched.

Each deploy also points `ymer-node:previous` at the revision the install was
running before it, so going back is two commands in the install and no sha to
look up:

```sh
docker tag ymer-node:previous ymer-node:latest
docker compose up -d
```

The deploy says what `previous` ended up naming, or why it named nothing — the
first deploy onto an install built before revisions has no label to read.

The node then serves MCP at `http://127.0.0.1:8012/mcp`. Its store lives in
`data/`, beside the compose file.

Point your MCP client at that URL. For Claude Code:

```sh
claude mcp add --transport http ymer-node http://127.0.0.1:8012/mcp
```

For Claude Desktop — and for Cowork, which reads the same file — add it to the
`mcpServers` object in `claude_desktop_config.json`, bridged through
[`mcp-remote`](https://www.npmjs.com/package/mcp-remote), which `npx` fetches
and runs — so the machine needs Node.js, which ships `npx`:

```json
"ymer-node": {
  "command": "npx",
  "args": ["mcp-remote", "http://127.0.0.1:8012/mcp", "--protocol", "auto"]
}
```

Keep `--protocol auto`. The node speaks only the 2026-07-28 revision of MCP,
and without the flag `mcp-remote` opens with the earlier revision's handshake,
which the node refuses — and `mcp-remote` exits on that refusal.

**Set `script_author` to ask before it runs.** Of the tools the node serves, it
is the one that decides what code this machine will run: storing a script
accepts it, and the node will run those bytes with its own permissions until
someone changes or removes them. A run is isolated from crashes and loops, and
it is not sandboxed — so the question worth your attention is not what a script
does but whether you meant to accept it. The other tools reach nothing but this
machine's own store and the scripts you already accepted.

**Set `schedules` to ask as well.** A schedule runs an accepted script's action
unattended, for up to 90 days, so adding one is the other decision worth your
attention: which action, how often, and for how long. `references` runs
scripts too — reading a reference with nothing cached, or refreshing one, runs
its script's URL action, and `watch` keeps that running for up to 12 hours —
so set it to ask if each of those should be your call.

The operator's verbs run on the machine itself, and are the door for anything
that should not travel through a model's context:

```sh
docker exec -i <container> /app/bin/ymer-node scripts list
docker exec -i <container> /app/bin/ymer-node scripts import < /path/to/script.exs
printf 'the-value' | docker exec -i <container> /app/bin/ymer-node secrets set NAME
docker exec -i <container> /app/bin/ymer-node throttles list
docker exec -i <container> /app/bin/ymer-node schedules list
```

A secret's value is read from stdin and never taken as an argument: an argument
is visible in `ps` to every user on the machine, and in your shell's history to
you. An imported script arrives on stdin the same way; `scripts import <file>`
takes a path inside the node's own filesystem instead. The `-i` is load-bearing
for both: without it nothing arrives, and the verb says so. `ymer-node help`
lists every verb.

A script may send its requests through a throttle it declares, which the node
starts the first time a request names it. When a run is refused because a
throttle's breaker is open — the system behind it answered 401 too many times in
a row — `throttles list` shows every throttle's state, and once the cause is
fixed, `throttles reset <name>` closes the breaker. The reset is this machine's
alone: no session can reach it.

`TZ` in a `.env` beside the install's compose file sets the node's time zone —
an IANA name such as `Europe/Helsinki`, applied with `docker compose up -d`
there, and what every script reads through
`YmerNode.Script.Context.time_zone/1`; unset, the node runs in `Etc/UTC`, and
a name the node does not know refuses boot, so the node never starts serving
and the refusal, naming `TZ` and the value, is read with `docker compose logs`
rather than through an operator's verb, each of which is a call into a serving
node.

### Store and backup layout

Inside that directory the store is `data/db/notebook.db`, and each backup the
node takes is one file, `data/backups/notebook-<id>.db`. The backups directory
is also how a kept notebook comes back into an install: put the file there under
that name, then call the notebook tool's `restore` with its id. The node backs
up the current store before it swaps, so the step itself can be undone.

Beside the store sits `data/db/node.db`, the node database — the registry the
`references` tool serves. It is migrated at every boot and never backed up:
delete it and the next boot recreates it, empty and current, which is why the
backups above are the store's alone. One thing to know while registry sync is
still to come: a reference you add lives only on this machine, so `node.db`
holds the only copy of it. `DATABASES_PATH` names the directory both files sit
in — `/data/db` in the compose file — and the file names inside it are fixed.

Beside both sits `data/files/`, the files directory — the one place a file
crosses between you and a script. Drop a file there, or have Cowork or Claude
Code drop it, and a script reads it; what a script writes there, you open.
Arrange sub-directories as you like: a script reaches the directory through
`YmerNode.Script.Context.files_dir/1` and `File`, never a path of its own, so
the same script works on every node. `FILES_PATH` names it in the compose file
as `DATABASES_PATH` names the databases' directory, `/data/files`, and it
stays inside the mount. The files are yours, not the node's: it creates the
directory at boot and never backs it up.

Beside them sits `data/cache/`, the cache directory: where the references
cache keeps what a script fetched as a file — a page, an image, a document.
It is the node's, not yours, and rebuilt with `node.db`: every boot removes the
files no cache entry names, so deleting `node.db` empties it, and a file gone
from it is fetched again the next time its reference is read. `CACHE_PATH`
names it, `/data/cache`, inside the mount and never inside the files
directory — a path there refuses boot.

On a brand-new store the node's first boot logs `database is locked` once while
its connections race each other to put the fresh file into WAL mode. It is
expected, it is over in milliseconds, and nothing is lost. A restore does not
produce it: the node switches the restored copy to the journal mode the pool is
configured for before the pool ever sees it.

That address is not a default — it is the security model. `/mcp` carries no
authentication, and not being reachable from the network is the whole
compensating control, which is why the published port is hardcoded to
`127.0.0.1`. Do not widen it without putting authentication in front of it first.

## Writing a script

A script is a small Elixir module the node compiles and runs — how it reaches
a system it has no built-in support for. Your session writes it: tell it to
read `scripts guide` first, which renders the script contract and the
functions a script is handed from the node's own docs — and `scripts info
<name>` for a package the guide promises, which renders that package's own
docs from the release at the version it carries — and to check the code
with `script_author` before it creates anything. Published, the same text —
less the list of applications the guide ends with, which the node computes —
is the `YmerNode.Script` and `YmerNode.Script.Context` pages of the docs, which
`mix docs` builds here. Keep `script_author` set to ask, as *Running it* says:
what it creates, the node runs. What a script can reach beyond that contract
— the standard library, a library, a service such as the browser service —
and the test that decides when the node itself grows are mapped in
[Scripts — batteries and their boundary](docs/scripts.md).

A script can also be developed in a repository of its own, with tests of its
own and a live run against the real systems: take `ymer_node` as a dependency
under `runtime: false` — its code without its application — and read the
`YmerNode.Script.Test` page of the docs for testing a script, and the
`YmerNode.Script.Harness` page for a live run.

A secret a script declares is set on this machine, by you, under the name the
script declares — never through the session: the `secrets set` line under
*Running it*, with that name.

Sharing a script is sharing its code. From a session, `scripts describe` with
`code: true` answers the code, to be saved to a file; on the machine,
`scripts export <name>` prints exactly the bytes the node holds and
`scripts import` reads them back, so the pair moves a script between nodes
unchanged. In the compose install the container is `<project>-ymer-node-1`,
the project being the install directory's name unless `COMPOSE_PROJECT_NAME`
says otherwise — `docker ps` shows it:

```sh
# on the sending machine
docker exec <container> /app/bin/ymer-node scripts export hex > hex.exs
# on the receiving one, with hex.exs carried across
docker exec -i <container> /app/bin/ymer-node scripts import < hex.exs
```

A release run on the host rather than in the image has the same verbs at
`bin/ymer-node`:

```sh
bin/ymer-node scripts export hex > hex.exs   # sending machine
bin/ymer-node scripts import < hex.exs       # receiving one
```

The two halves are two machines. Importing an exported script back into the
node it came from is a write like any other: it re-lands the row through the
import door, so a script the build planted stops reading as the build's.

On the receiving node the session checks the code and creates it — acceptance
is that node's own — and whoever runs that machine sets the secrets it
declares. The example scripts the image ships — `hex`, and `webpage`, which
reads any web page no other script claims as markdown for the references
cache — are already there on a fresh install, to be read as much as run;
remove one and it stays gone.

## The browser service

A script drives a browser through the browser service: a small Node program in
`browser-service/` that runs on your own machine, outside the node, and runs
the Playwright code a script sends it — each call in a fresh browser context.
The browser, Playwright and Node.js stay out of the node's image, since most
nodes never use them, so the service is yours to start; a node without one
runs every other script as before, and a browser call refuses with what to
run.

It needs Node.js 20 or later. First-time setup, in a clone of this repository:

```sh
cd browser-service
npm install    # the pinned Playwright, and the Chromium builds it drives
npm start
```

`npm start` serves on `127.0.0.1:8013`, and refuses to start — naming the fix —
when the browser build is missing or the port is taken; `BROWSER_SERVICE_PORT`
moves it. A node run on the host finds it there with nothing to configure, and
so does the node's image on macOS Docker, through `host.docker.internal`.
Anywhere else, set `BROWSER_SERVICE_URL` — in the install's `.env`, like `TZ`
— to the address the node reaches the service at. Linux Docker is not
promised: the default address does not reach a service bound to the host's
loopback there. `scripts browser`, from a session or as an operator's verb,
says whether anything answered and what the service holds.

A login a script should reuse is a **storage state** — the browser's cookies
and local storage, kept by name. To make one by hand, or to refresh it, open an
interactive window on its name while the service runs:

```sh
npm run window -- intranet
```

Log in, work as long as you like, and close the window: the state is written
every minute while it is open and again when it closes, and a scheduled script
reading that name is logged in too. While the window is open a script may read
the state but not save over it. The states are files in
`~/.ymer-node/storage-states/` — `BROWSER_SERVICE_STORAGE_DIR` moves it — the
directory `0700` and each file `0600`, and the service refuses to read one
anyone else can, naming the `chmod`. They hold live logins, so they belong in
no git tree and never pass through the node.

The service binds loopback, like the node, and refuses any request shaped like
one from a web page: an `Origin` header, a body that is not JSON, or a `Host`
that is not this machine. Loopback does not keep other programs out — every
container on a Docker host reaches the service the way the node's image does —
and a browser call's code runs with your privileges, so every request must also
carry the service's token. The token is a random value in
`~/.ymer-node/browser-service-token`, `0600`, which `npm start` writes the first
time; `BROWSER_SERVICE_TOKEN_FILE` moves it, for the service and for a node run
on the host alike, and such a node reads it with nothing to configure. A node in
Docker cannot read that file: copy its contents into the install's `.env` as
`BROWSER_SERVICE_TOKEN`. A request without the token is refused with where to
find it.

Upgrading Playwright is a commit that moves its pin in
`browser-service/package.json`; the next `npm install` fetches the browser
build the new version drives.

## Developing it

```sh
mise exec -- mix deps.get
mise exec -- mix test
mise exec -- mix precommit
```

`precommit` is the gate: compile with warnings as errors, format, Credo, a
dependency audit, the test suite, and `mix ymer_node.browser_check` — the
browser service's own tests, which need Node.js 20 or later and install the
service's packages and browser builds on their first run.

`mix ymer_node.consumer_check` runs apart from it: it builds a project that
depends on this checkout under `runtime: false` and runs that project's tests,
which is how the published script test support is proved where the node's
application does not run.

A fresh clone with no sibling checkouts must build and pass that gate on its own.
That is a standing requirement rather than a happy accident — if you find yourself
reaching for a neighbouring directory to make something work, the fix belongs in
this repository.

To smoke-test the compose file against this checkout's build, run it here under
a project name and a port of its own, so it never collides with the install:

```sh
mise exec -- mix ymer_node.build
PORT=4013 docker compose -p ymer-node-smoke up -d
docker compose -p ymer-node-smoke down
```

Between `up` and `down` the node answers at `http://127.0.0.1:4013/mcp` — that
address, not the 8012 of "Running it", where the node you keep may be answering
and would pass for this build. 4013 is the test port `config/test.exs` reserves
and leaves unbound.

## Where to look next

- `YmerNode` — the map: what exists, what each module owns, and why it exists.
  Start here before changing code.
- [Glossary](docs/glossary.md) — the canonical vocabulary.
- `LICENSE` — Apache-2.0.
