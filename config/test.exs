import Config

# SQLite plus Ecto.Adapters.SQL.Sandbox does NOT support `async: true` — the
# store is single-writer, so `use YmerNode.NotebookCase` without the async flag.
# busy_timeout absorbs the brief writer contention the sandbox can still produce.
#
# One connection, deliberately, where every other environment runs five. The
# sandbox hands one connection to one test at a time, so a pool of five bought
# the suite nothing and created the one race the sandbox cannot retry: stopping
# a test's owner returns its connection AFTER `stop_owner/1` answers, so the next
# test's owner was handed a different connection while the previous one still
# held the write lock inside its uncommitted transaction — and a write attempted
# inside a read transaction is answered SQLITE_BUSY without the busy handler ever
# being consulted (SQLite retries a write only from outside a transaction). With
# one connection the next owner waits for the previous connection to come back,
# rolled back, and the race has nothing to run on. Measured before this line:
# 16 of 20 runs of the actions tests under one seed failed their first
# `CREATE TABLE` with "Database busy".
config :ymer_node, YmerNode.Notebook.Repo,
  database:
    Path.expand("../ymer_node_notebook_test#{System.get_env("MIX_TEST_PARTITION")}.db", __DIR__),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 1,
  journal_mode: :wal,
  busy_timeout: 5_000

# The node database's own sandbox. `pool_size: 2` is a floor, not a preference:
# the `Ecto.Migrator` child runs migrations inside a `Task`, which needs a
# second connection while the starting process holds the first. At pool_size 1
# that task never gets one, waits out the queue window, and application start
# dies with `DBConnection.ConnectionError: could not checkout the connection
# owned by #PID<...> (Task.Supervised)`. Measured on this adapter with the
# migrator child in the tree: size 1 fails to boot, sizes 2 and 5 boot with
# every migration applied.
#
# The notebook repo's single connection answers a race this pool cannot escape
# the same way: stopping a test's owner returns its connection AFTER
# `stop_owner/1` answers, so the next owner can write through a fresh connection
# while the previous one still holds the write lock inside its uncommitted
# transaction — and SQLite answers that SQLITE_BUSY without ever consulting the
# busy handler. That race needs a pool larger than one, so two does not sit
# outside it; two is simply the smallest pool that boots here. If `Database busy`
# ever shows up in these tests, neither obvious lever is the fix: a larger pool
# is the direction that created the notebook's race, and busy_timeout is never
# consulted for this one.
config :ymer_node, YmerNode.Repo,
  database: Path.expand("../ymer_node_test#{System.get_env("MIX_TEST_PARTITION")}.db", __DIR__),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 2,
  journal_mode: :wal,
  busy_timeout: 5_000

# Every backup test overrides :directory (and usually :retain) per-test via
# Application.put_env; this block only keeps a non-partitioned default from
# leaking into the repo root.
config :ymer_node, YmerNode.Notebook.Backup,
  directory:
    Path.expand("../ymer_node_test#{System.get_env("MIX_TEST_PARTITION")}_backups", __DIR__),
  retain: 40

# The sandbox holds no checked-out connection at boot, so the probe would fail
# against a perfectly healthy build. Dev and a running container assert it.
config :ymer_node, YmerNode.Notebook.VecLoadCheck, enabled: false

# Port 0 binds an ephemeral port. The node's registered test port is 4013, but
# nothing in the suite reaches the server over HTTP — the tool surface is tested
# directly through the MCP framework's own test helpers — so binding a fixed
# port would only let two partitioned runs collide and fail application start.
config :ymer_node, YmerNode.Mcp, port: 0

config :logger, level: :warning

# Partitioned like the databases. `set/2` rewrites the file whole, so two
# partitions sharing one path would race. Every case that touches secrets also
# points the module at a tmp file of its own — but that is not enough to make
# the module async, because the pointer is this VM-global key:
# `YmerNode.SecretsTest`, `YmerNode.ScriptContextTest`,
# `YmerNode.ScriptHarnessTest` and `YmerNode.ScriptTestSupportTest` each set it,
# so each is `async: false` and says so in its own moduledoc.
config :ymer_node, YmerNode.Secrets,
  path:
    Path.expand("../ymer_node_secrets_test#{System.get_env("MIX_TEST_PARTITION")}.env", __DIR__)

# Every script request in the suite goes through Req.Test's stub instead of the
# network. A case exercising a script stubs it under the `YmerNode.Script.Context`
# name; one that forgets gets Req.Test's own "no stub" failure rather than a
# real outbound call. `retry: false` is carried through from the module's
# default, because a stubbed transport error would otherwise be retried three
# times and cost the case six seconds.
#
# The files directory is partitioned like the backups directory. Nothing creates
# it at boot in test — that mkdir is `config/runtime.exs`'s, prod only — so a
# case that writes a file there makes the directory first.
config :ymer_node, YmerNode.Script.Context,
  request_options: [retry: false, plug: {Req.Test, YmerNode.Script.Context}],
  files_dir:
    Path.expand("../ymer_node_test#{System.get_env("MIX_TEST_PARTITION")}_files", __DIR__)

# The loader compiles every accepted row inside its own `init/1`, which reads
# the node database — and at application start the sandbox holds no checked-out
# connection, so that read would fail against a perfectly healthy build. Same
# ground as the vector probe above, same shape: a configuration decision, not an
# environment sniff. `YmerNode.Scripts.LoaderTest` calls `boot_compile/0`
# itself, which is the boot path with an owner in hand.
config :ymer_node, YmerNode.Scripts.Loader, boot_compile: false

# The migration that plants the example script reads this before planting, and
# it is off here for the reason the loader's boot compile is: a test database
# must hold only what a case wrote, so every listing a case asserts on starts
# empty. `YmerNode.ScriptsTest` calls `plant_example/0` itself.
config :ymer_node, YmerNode.Scripts, plant_example: false
