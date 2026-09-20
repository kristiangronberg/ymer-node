# Scripts — batteries and their boundary

A script is logic over what the node hands it. This page maps what a
script author is likely to want onto where it comes from — the release, a
library, a service, an image of your own — and states the test that
decides when the node itself grows. The contract a script implements and
the calls it may rely on across releases are documented once, at
`YmerNode.Script` (*What a script may call*) and `YmerNode.Script.Context`;
this page points there and never restates them. A promised package's own
documentation is one call away in a session — `scripts info <name>` renders
it from the release at the version it carries. Terms:
[*script*](glossary.md#script), [*battery*](glossary.md#battery),
[*declaration*](glossary.md#declaration),
[*files directory*](glossary.md#files-directory).

## The boundary

In scope: reaching another system and moving or transforming data — read
what it holds into a shape a worker can use, write what a worker produced
into the shape the system accepts. A periodic report compiled from any
data the user points at is in scope; so is a browser-driven test of a
web UI.

Out of scope: serving. The node has no user-facing listener and a script
gets none. A script compiles and pushes its output to a host; it never
hosts. A framework that exists to serve — a web server, a UI — is the
shape that is too large for a script.

## Where a capability comes from

Five rungs, tried in order. A request for "libraries X and Y" is answered
by the first rung that fits.

1. **The release already has it.** Elixir's and Erlang/OTP's standard
   libraries reach further than most authors expect: `EEx` templating,
   `:zip`, `:erl_tar` and `:zlib`, `:crypto` and `:public_key` (hashing,
   HMAC, signatures), `Date` and `DateTime`, `File` and `Path`. One
   caveat: a release ships only the OTP applications its dependencies
   need, so an OTP application outside that set — `:ssh` as of this
   writing — is absent until a use case adds it.
2. **A library.** Shared Elixir code authored like a script and declared
   by the scripts that use it: the home for anything expressible in
   Elixir at the size of a module or a few — a converter, a client, a
   protocol.
3. **A service over HTTP.** The node is an integration host, so a
   capability that exists as a service is reached the way any system is:
   a PDF renderer, a browser, an LLM or embedding API. No battery, and
   often the better operational shape.
4. **An image of your own.** The node is open source and its Dockerfile is
   the build. An organisation with a native need the stock node does not
   carry builds its own image with the dependency added; the script
   contract is unchanged. The promise in `YmerNode.Script` covers the
   stock image only.
5. **A battery.** The node itself grows, through its roadmap, when a use
   case in hand needs something no library can be:
   - native code — a compiled extension the running node cannot build
     from a script's text;
   - a node-owned process or configuration — a throttle shared by
     several scripts, a token cache, a connection pool;
   - a package a library would only vendor — thousands of lines with
     their own upkeep;
   - a format so common that every integration host is expected to speak
     it, where a good library exists. Forcing every author to replicate a
     good library the release could carry is waste; the bar is ubiquity
     plus a good library, never a good library alone. Parquet is the
     counter-example — cool, but a much less used format with no direct
     use case here, so not defensible.

   A use case in hand, never a category, for the first three reasons: a
   battery joins for a script someone is writing. The fourth names its own
   use case — every integration host's.

## The survey

What script authors on comparable platforms reach for — the classes are
those of Google Apps Script's services, n8n's core nodes and Huginn's
agents — and where each lands here. *Planned* marks a battery the node
intends and has not released.

| Class | Needs | Where it comes from |
| --- | --- | --- |
| HTTP APIs, JSON | `Req`, `JSON` | the release |
| Rate limits, lockout protection | a throttle keyed by name | the release |
| HTML to markdown, markdown out | Floki, MDEx | the release |
| OAuth2 client flows, token refresh | a token cache per name | a battery when a use case arrives |
| Templating, reports | `EEx` | the release |
| Files, zip, tar, gzip | `File`, `:zip`, `:erl_tar`, `:zlib` | the release |
| Files on the host | the files directory, `YmerNode.Script.Context.files_dir/1`, and `File` | the release |
| XML, RSS, SOAP | read: sweet_xml over `:xmerl`; write: saxy | the release |
| CSV, XLSX | CSV: nimble_csv; read XLSX: xlsx_reader; write XLSX: elixlsx | the release |
| Time zones | `DateTime` over the release's zone database; the node's time zone, `YmerNode.Script.Context.time_zone/1` | the release |
| Email, send | gen_smtp | a battery when a use case arrives; Outlook and Gmail over HTTP need nothing |
| Email, read | IMAP | a service: Graph or Gmail over HTTP |
| SSH, SFTP transfer | `:ssh` | one release line when a use case arrives |
| PDF | typst | the release |
| Web UI test automation | Playwright | planned; the browser itself is a service |
| Images, charts | vix, image | a service or an image of your own; SVG through `EEx` needs nothing |
| Crypto, JWT, TOTP | `:crypto`, `:public_key`; jose | the release; TOTP is a library; JWT a battery when an assertion flow needs it |
| Scheduling | a trigger | a node feature, not a battery |
| Storage, state, vectors | the notebook | the release |
| Shell commands | `System.cmd/3` | reachable under the trust model, never promised |
