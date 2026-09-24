# Glossary

Canonical domain terms for this project. Code and docs use these terms;
`_Avoid_` synonyms are banned in new names. Conceptual terms are defined here;
code-backed terms are defined at their code home and linked from here; principles
and invariants are defined in their prose home and pointed at from here. Every
other document uses a term and points at its home, and never redefines it.

This glossary describes what is: an entry is written when the thing its term names
is real. That is why it is short — the node's vocabulary grows as the node does.

## A

### acceptance
Defined in `YmerNode` — the app map's Scripts section stating that a script runs
only while its accepted hash equals its code hash, and which doors accept.
_Avoid_: approval (the client's act is the door; acceptance is the node's
record), trust, enable, activate, install (for a script)

## B

### backup
`YmerNode.Notebook.Backup`
_Avoid_: snapshot

### battery
A capability the node carries for every script, so no script declares or
vendors it — in two shapes: what the context hands a run,
`t:YmerNode.Script.Context.t/0`, and a *promised package*.
_Avoid_: SDK, runtime, helper, stdlib (for it); *context* stays the word for
the struct itself and never becomes a term of its own

### bind marker

The empty file the node's image writes at build, at a fixed path the release
checks at boot; its presence is what makes the release bind all interfaces
inside the container, and nothing else does.

_Avoid_: bind flag, wide-bind switch, bind env (there is no variable)

## C

### CLI
The release's operator verbs — `bin/ymer-node`, the overlay beside the release's
own launcher — run by a human on the machine the node runs on; the node's own
human door, beside the client's approval. Implemented by
`YmerNode.Scripts.CLI`.
_Avoid_: shell (the distribution's menubar app), console, command line (as the
term)

## D

### deadline
Defined in `YmerNode.Scripts.Runner` — the `@moduledoc` section *The
deadline*, stating the bound on one run and that a run past it is killed.
_Avoid_: timeout (for the bound — an action's `timeout` key is its request,
`:timeout` the answer a killed run gives), time limit, cap (bare)

### declaration
`t:YmerNode.Script.declarations/0`
A *source declaration* is what references derive from an accepted script's
declaration.
_Avoid_: manifest, capabilities, permissions, config

### deploy
`Mix.Tasks.YmerNode.Deploy`
_Avoid_: upgrade, redeploy

### durability rule
Defined in `YmerNode` — the app map's opening paragraph on what the node
keeps.
_Avoid_: one precious file, single-store rule, one-database rule, backup
rule

## E

### example script

The script the image ships and a fresh install holds — `Script.Hex`, planted
by a migration on a fresh node database, present to be read as much as run;
removable, and removal sticks.

_Avoid_: sample, default script, built-in script (built-in is the reference
sources' word), template, seed (for it)

## F

### fetch recipe
`YmerNode.References.Sources.classify/2`
_Avoid_: resolver, resolve, handler, fetcher

### files directory
`YmerNode.Script.Context.files_dir/1`
_Avoid_: folder, files folder (the human word, never the term); node
files (the node's own things take that head — these files are the
user's); inbox, outbox, drop folder, gateway, share, exchange
directory; mount, volume (for it — the mount is `/data`, which holds
it); `FILES_PATH` names the variable that sets it, never the directory

## G

### guide
The text `scripts guide` renders from the docs of `YmerNode.Script` and
`YmerNode.Script.Context` — each moduledoc and the documented types, callbacks
and functions beneath it: the script contract, the batteries, what a script
may call, the loop, the secrets and sharing flows — the same bytes the
published docs show, followed by one section the node computes at render: the
applications the running release carries. Rendered by `YmerNode.Scripts.Guide`.

_Avoid_: tutorial, manual, docs (for it), instructions (the MCP field), notes
(the action key), help (the tool that names it)

## I

### import
`YmerNode.Scripts.import/1`
_Avoid_: push (the verb before the rename — the CLI accepts it as a
synonym only), load (the loader's word for compiling a script into the
VM), upload, install (for a script)

### install

The kept copy of the node on a machine: the directory holding its store, its
`secrets.env` and the compose file, and the container compose runs from there.
Stopped or removed, the container leaves the install in place; the checkout's
smoke on its own port is not one — nothing there is kept.

_Avoid_: install dir (as a term of its own — the install's directory is the
install), the directory you keep, runner compose, prod (as a noun for it)

## L

### live output
`Mix.Tasks.YmerNode.Build.LiveOutput`
_Avoid_: streamed output, streaming output, progress output, console
output, relay, sink, echo

## M

### membrane
Defined in `YmerNode.References` — the `@moduledoc` section stating that a
reference is a pointer, never content.
_Avoid_: find-don't-re-document, pointer rule

## N

### node

A running Ymer Node install.

Four other compounds stay qualified wherever they are meant: a **BEAM node**, a
**Mermaid node** and an **AST node**, which are three other senses of the word,
and the **node database**, which is this sense's own and is always named in full
so it never reads as a bare node. Bare "node" in this repository's prose is
always this entry.

### node database

`node.db`, with its `-wal`/`-shm` companions beside it — the node's own
mix-managed database beside the store, whose schema this codebase owns and
migrates at boot. Rebuildable and never backed up: delete it and the next boot
recreates it empty. Until registry sync lands it holds the only copy of every
reference added on this node, and of every script authored here.

_Avoid_: cache, node store, second store, node db

### node time zone
`YmerNode.Script.Context.time_zone/1`
_Avoid_: timezone, time-zone; local zone, operator's zone, machine
zone, this node's zone (as terms — prose says "the node's time zone");
`TZ` names the variable that sets it, never the fact; local time (a
wall-clock reading, not a zone)

### notebook
`YmerNode.Notebook`

## O

### origin
`t:YmerNode.Scripts.Script.origin/0`
_Avoid_: provenance, source, door (the informal word in prose)

## P

### policy
The options the node merges underneath a script's own when a battery is
called through the context — facts of the machine and the run a script
never learns — so a script passes nothing and may override anything. A
call that goes around the context carries none.
_Avoid_: seam (for it — *seam* stays this repo's word for a join point,
the references seam), wrapper, facade, defaults (bare — a package's own
default is the package's), node defaults; *client policy* is ymer's term
and stays qualified

### promised package
A battery a script calls as a package: one the table in `YmerNode.Script`
§ What a script may call promises for one job, at the line its last column
names, whose own docs `scripts info <name>` renders from the release. What
the release carries beyond them is reachable and not promised.
_Avoid_: dependency (for it — every package in `mix.exs` is one; a promised
package is the subset the table names), library (the standing doc's word
for shared script code), battery (bare, for it)

## R

### reference
`YmerNode.References.Reference`
_Avoid_: entry, bookmark, link; pointer (as the entity name — "pointer" stays
the informal concept word in membrane prose); *image reference* stays
compound-qualified for the Docker sense in `Mix.Tasks.YmerNode.Deploy`

### references
`YmerNode.References`
_Avoid_: knowledge index, information router, reference layer

### registry

The node's set of references: the rows in the node database the `references`
tool serves. Until registry sync lands, this registry is the only copy of them.

_Avoid_: index, knowledge index, catalog, reference layer. A **process
registry** — Elixir's `Registry`, or the name a supervised process is
registered under — stays compound-qualified wherever it is meant.

### revision

The git commit a build was made from, as its short sha, marked when the tree
was dirty. An image built from a git checkout carries it three ways: as the
OCI revision label, as the `ymer-node:<revision>` tag, and inside
`serverInfo.version` as `<version>+<revision>`. A build that could name none —
no git, or no work tree — carries it nowhere and answers the bare version.

_Avoid_: stamp, sha stamp, build id

### run tree
`YmerNode.Script.Harness.run_tree/0`
_Avoid_: throttle tree (it holds more than throttles), node processes,
script-run process subset; *registry* unqualified — a process registry stays
compound-qualified

## S

### safety backup
`YmerNode.Notebook.Backup.restore/1`
_Avoid_: undo anchor, regret button

### script
`YmerNode.Scripts.Script`
_Avoid_: extension, plugin, program, integration (as the thing); tool (a script
is served by the `scripts` tool, it is not one)

### script contract
`YmerNode.Script`
_Avoid_: behaviour (bare — the word for any Elixir behaviour), extension
contract, API

### secret
`YmerNode.Secrets`
_Avoid_: credential, token (for it — a *bucket's token* is the throttle's word), env var, api key

### serverInfo
Defined by wymcp; its definition lives there, not here. This node's
`name` and `version` on it come from application config, never from the
router option.
_Avoid_: server info, server identity

### serving
Defined in `YmerNode.Notebook` — the `@moduledoc` section stating the serving
rule.
_Avoid_: ready, readiness, healthy, up (for serving), running (for serving —
`YmerNode.Notebook.Repo.running?/0` keeps its structural meaning)

### source
`t:YmerNode.References.Sources.source/0`
_Avoid_: system, kind, provider, classification (as the term — it is the
definition's word); origin (for the classification — the word names a script
row's provenance); **source code**, **source file** and **open-source** stay
compound-qualified, and a script's Elixir text is its **code**, never its
source

### source declaration
`t:YmerNode.References.Sources.declaration/0`
Derived from an accepted script's *declaration*, which is the wider term.
_Avoid_: source config, host mapping, URL pattern

### store

The notebook's database file — `notebook.db`, with its `-wal`/`-shm`
companions beside it — the one thing the node keeps. A backup is a
single-file copy of it; a restore replaces it whole. Not the node database,
which sits beside it and is rebuildable.

_Avoid_: database file, db file, notebook file, the sqlite, the data (for
the file — `data/` is the install's directory, which holds the store).
Never *store* as the verb for landing a script: a script is created,
updated or imported, and the node *holds* it.

## T

### tag invariant
Defined in `Mix.Tasks.YmerNode.Build` — the `@moduledoc` section on what moves
`ymer-node:latest`.
_Avoid_: latest invariant, tag rule

### throttle
`t:YmerNode.Script.throttle/0`
_Avoid_: gate, rate limiter, limiter, rate limit (the class, never the thing)

## W

### what a row cannot say
A sentence the node writes beneath the table in `YmerNode.Script` § What a
script may call, stating a fact about a promised package that the package's
own docs do not — the node's knowledge, never library teaching.
_Avoid_: warning (a compiler's and a logger's word here), gotcha, caveat,
note

## Y

### Ymer Node

The open-source, Docker-shipped, headless local companion to ymer: an MCP node
providing local capability — the notebook, the references registry and the
scripts it accepts — to LLM workers whose coordination lives in ymer. One product
together with ymer, and no UI of its own.

_Avoid_: Ymer Desktop, Ymer Local, Ymer Dev (all rejected as names); desktop app
(it is headless, and has no window to show anyone).
