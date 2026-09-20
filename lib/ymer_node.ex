defmodule YmerNode do
  @moduledoc """
  This module is the **map** — what exists and why. Each entry defends a module's
  existence; how a module is designed lives in its own `@moduledoc`.

  Ymer Node is the headless local half of one product. It gives an LLM worker
  capability that has to live on this machine, while the coordination that has to
  be reachable from anywhere lives in ymer. It has no UI of its own and no work
  engine, and it never routes work. A client reaches it over MCP at `/mcp`, on
  loopback — pinned by the bind when the node runs directly, and by the host
  publish when it runs in a container (`YmerNode.Mcp` owns that distinction).

  Two properties shape everything below. **Local serving never depends on ymer**:
  every tool here answers whether or not the node can reach anything, so an
  unreachable ymer degrades identity, never capability. And **the node owns one
  precious thing** — `notebook.db`. Everything else it holds is rebuildable, which
  is why exactly one subsystem has a durability obligation. That is the
  **durability rule**, and "rebuildable" is the admission test for anything else
  the node stores. `node.db` is what the rule has admitted so far: its schema is
  this codebase's and migrations run at every boot, so deleting it costs nothing
  a boot does not put back. It is never backed up, and "back up the node" goes
  on meaning the store alone. The files directory a script reads and writes
  (`YmerNode.Script.Context.files_dir/1`) sits outside the rule altogether: the
  node creates it and never touches its contents on its own, so the files there
  are the user's — neither precious to the node nor rebuildable by it.

  ```mermaid
  flowchart LR
      Mcp[MCP mount]
      Notebook[Notebook]
      Backup[Notebook/Backup]
      References[References]
      Scripts[Scripts]

      NotebookDB[(notebook.db)]
      NodeDB[(node.db)]
      BackupFiles[(backup files)]
      SecretsFile[(secrets.env)]
      FilesDir[(files directory)]

      Mcp -->|"serves the notebook tool"| Notebook
      Mcp -->|"capture and restore"| Backup
      Mcp -->|"serves the references tool"| References
      Mcp -->|"serves the scripts and script_author tools"| Scripts
      Notebook -->|"the lock's held op, to tell a restore's window apart"| Backup
      Notebook --> NotebookDB
      References -->|"declarations of accepted scripts"| Scripts
      Scripts -->|"reserved names, claimed hosts"| References
      References --> NodeDB
      Scripts --> NodeDB
      Scripts -->|"a run's batteries"| Notebook
      Scripts --> SecretsFile
      Scripts -->|"a run reads and writes files"| FilesDir
      Backup -->|"VACUUM INTO"| NotebookDB
      Backup --> BackupFiles
  ```

  ## The notebook

  `YmerNode.Notebook` is the raw-SQL surface over `notebook.db` — a store whose
  schema belongs to the user and the LLM, not to this codebase. It owns no
  `Ecto.Schema` and ships no migrations; the agent issues its own DDL. The module
  is thin by design: the only behaviour beyond pass-through is the safety model
  (a rollback that makes reads provably read-only, and a block on the verbs that
  would reach outside this database) and a `_meta` description layer that gives
  SQLite the column comments it lacks.

  `YmerNode.Notebook.Repo` exists to give that store a supervised connection pool
  and to load the vendored sqlite-vec extension on every connection, so vector
  tables and KNN search are available through the same SQL surface as everything
  else. `YmerNode.Notebook.VecLoadCheck` is the boot probe that turns a silently
  failed extension load into a refusal to start.

  ## Backup

  `YmerNode.Notebook.Backup` is a notebook operation, not a subsystem beside it:
  the node has exactly one database worth retaining, so "back up" and "back up the
  notebook" are the same act. That is a statement about what it owns, not about who
  calls it — the tool layer reaches it directly, which is why the map above draws
  an edge from the mount and not only through `YmerNode.Notebook`. The edge the
  other way is narrow and one-directional: `YmerNode.Notebook` reads the lock's
  held op to tell a restore's window — the one stopped state that closes on its
  own — from every other one, a rule its own moduledoc owns.
  `YmerNode.Notebook.Backup` is deliberately a separate, privileged path from the
  agent's SQL surface — it replaces the store whole, which is not something a
  prompt-injected agent may reach. `YmerNode.Notebook.Backup.Lock` serialises
  capture against restore.

  ## References

  `YmerNode.References` is the registry: the node's set of references, each a
  pointer naming where knowledge lives and when to look, never what it says. It
  exists because a worker that re-documents what already lives somewhere has
  made a second copy to keep in step, while a pointer and the call that follows
  it stay correct on their own. The rule that keeps a reference a pointer — the
  membrane — is stated there, and it is the reason this context stores no
  fetched content and the tool never fetches.

  `YmerNode.References.Sources` derives a reference's source and fetch recipe
  from its uri at read time, against declarations that accepted scripts supply,
  so what a reference resolves to follows the node's current capabilities rather
  than whatever was true when the row was written.
  `YmerNode.References.Search` is the ranked find over the registry, and owns
  the mode contract.

  `YmerNode.Repo` is the node database's repo and the exact counterweight to
  `YmerNode.Notebook.Repo`: this one owns its schema and ships the migrations
  that make `node.db` rebuildable, which is precisely what the notebook's repo
  must never do.

  ## Scripts

  `YmerNode.Scripts` is the third capability: small Elixir modules the node has
  **accepted**, compiled into this VM and run on request. It exists because the
  node cannot ship a tool for every system a worker needs to reach, and because
  the systems worth reaching are different on every machine — a script is how
  this node learns to reach one without a release.

  **The boundary is which scripts are accepted.** A run is isolated from crashes
  and from loops — its own supervised process, its own deadline, killed when the
  deadline passes — but it is **not sandboxed**: an accepted script runs with the
  node's own permissions, reaches the network and the notebook, and could do
  anything this process could do. Nothing about the run limits that, so the
  question the design answers is not *what may a script do* but *which code is
  this node willing to run*. The answer is: exactly the bytes someone accepted,
  and nothing else.

  That is the **acceptance** invariant, and it is one comparison. A row carries
  the hash of its code and the hash this node accepted; `run` refuses unless the
  two are equal. Code that changed after it was accepted is code nobody accepted.
  Three doors accept today — an MCP client through `script_author`, a human
  through the CLI, and the build, whose example script a migration plants on a
  fresh node database at exactly the bytes the image carries, because whoever
  built the image read them — and each is a deliberate act by someone who can
  read what they are landing. A fourth, registry sync, is why the unaccepted
  state exists at all before any door can produce it.

  `YmerNode.Scripts.Script` is the row: the code, the two hashes, and the
  description and declarations denormalised from the compiled module so a listing
  and the references seam are one query each. `YmerNode.Scripts.Compiler` turns
  code into modules and refuses, before compiling anything, a module it can see
  defined outside `Script.` — a guard against the honest mistake, not a second
  boundary, because a module body runs while it compiles and the door that
  decides what compiles at all is the one above. `YmerNode.Scripts.Loader`
  owns every compile and purge in one process, and holds what this boot knows
  about each script. `YmerNode.Scripts.Runner` is one run: the acceptance check,
  the argument check, the deadline, and the shape of every answer.
  `YmerNode.Script` is the contract a script implements and
  `YmerNode.Script.Context` the batteries it is handed — Req, the notebook,
  secrets, throttles, the node's time zone, the files directory, the Typst
  renders — which is why a script needs no dependencies of its own.
  `YmerNode.Scripts.Throttle` is the one battery that is a process: one per
  throttle name, shared by every script and run naming it, holding the bucket
  and the breaker the account behind the name needs. `YmerNode.Scripts.Guide`
  renders the two, at the call, as the text `scripts guide` answers: the
  contract has one home, a client reads the same bytes a developer reads on the
  published docs, and the guide ends with the one thing only the running node
  can say — the applications its release carries. `YmerNode.Scripts.PackageDocs`
  renders a promised package's own docs the same way, at the version the
  release carries, as `scripts info <name>` answers: the guide stays a map from
  job to package, and the node authors promises and
  [*what a row cannot say*](docs/glossary.md#what-a-row-cannot-say), never
  library teaching.

  `YmerNode.Secrets` keeps the values a script resolves by name, in a file beside
  the databases rather than in one. That is the durability rule holding: a
  secrets table would make one row of `node.db` precious and the rule would have
  to grow an exception, where a file leaves it intact and costs a re-set rather
  than a restore.

  `YmerNode.Scripts.CLI` is the operator's door, run on the machine itself —
  where pushing a file from a repository and setting a secret that must never
  pass through a model's context both belong.

  ## The MCP surface

  `YmerNode.Mcp` is the mount: the node's entire external surface, and the one
  place its tool list is declared. `YmerNode.Mcp.McpServer` holds the instructions
  a client is handed at connect — including the paragraph naming ymer as the other
  half of the product, which is the only way a client learns the node is not the
  whole story. `YmerNode.Mcp.Tools.Notebook`, `YmerNode.Mcp.Tools.References`,
  `YmerNode.Mcp.Tools.Scripts` and `YmerNode.Mcp.Tools.ScriptAuthor` are the
  tools themselves, each a thin boundary over its own context;
  `YmerNode.Mcp.Tools.Helpers` holds the handful of shaping functions their
  action layers share, and `YmerNode.Mcp.Tools.ScriptFormat` the rendering the
  two script tools share.

  Running and authoring are two tools rather than one so that a client can be
  granted the first without the second: what runs is bounded by what has been
  accepted, and accepting is the decision worth a human's attention.
  """
end
