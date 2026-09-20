import Config

# The notebook DB lives at the project root and is gitignored (*.db). WAL plus a
# generous busy_timeout mirror the container defaults, so dev behaves like a
# running node. The sqlite-vec extension is loaded by the repo's own init/2.
config :ymer_node, YmerNode.Notebook.Repo,
  database: Path.expand("../ymer_node_notebook_dev.db", __DIR__),
  journal_mode: :wal,
  busy_timeout: 5_000,
  pool_size: 5,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true

# The node database sits at the project root beside the notebook's, covered by
# the same *.db / *.db-* ignore rules. No sqlite-vec extension is loaded for it:
# nothing the registry holds is a vector.
config :ymer_node, YmerNode.Repo,
  database: Path.expand("../ymer_node_dev.db", __DIR__),
  journal_mode: :wal,
  busy_timeout: 5_000,
  pool_size: 5,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true

# Backups sit beside the dev DB at the project root; the *.db / *.db-* ignore
# rules already cover the files inside. `retain` is deliberately small in dev —
# a handful is enough to exercise pruning by hand.
config :ymer_node, YmerNode.Notebook.Backup,
  directory: Path.expand("../backups_dev", __DIR__),
  retain: 5

# The dev files directory sits at the project root beside the dev databases,
# committed as an empty directory — its .gitkeep — so a fresh clone has it and
# a dev node makes nothing by hand; what a developer drops in it stays out of
# git (.gitignore).
config :ymer_node, YmerNode.Script.Context, files_dir: Path.expand("../files_dev", __DIR__)

config :ymer_node, YmerNode.Mcp, port: 4012

config :logger, :default_formatter, format: "[$level] $message\n"

config :mix_test_watch, tasks: ["test"]

# The dev secrets file sits at the project root beside the dev databases, under
# the *.env ignore rule. Nothing in dev needs a secret until a script declares
# one; the file is created by the first `secrets set`.
config :ymer_node, YmerNode.Secrets, path: Path.expand("../ymer_node_secrets_dev.env", __DIR__)
