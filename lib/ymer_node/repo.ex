defmodule YmerNode.Repo do
  @moduledoc """
  Ecto repo for `node.db` — the node database, and the rebuildable half of what
  the node stores.

  Unlike `YmerNode.Notebook.Repo`, this repo owns its schema. The migrations
  under `priv/repo/migrations` belong to this codebase, and an `Ecto.Migrator`
  child runs them at every boot in every environment, so a missing file comes
  back empty and current. That is the whole of the rebuildable claim, and
  rebuildable is the admission test the durability rule (`YmerNode`) applies to
  anything the node stores beyond the store itself. Nothing here is backed up:
  `YmerNode.Notebook.Backup` captures `notebook.db` and only `notebook.db`.

  The file sits beside the store. The configuration that runs the node sets it
  under `config :ymer_node, YmerNode.Repo`: `:database`, the file's path, and
  `:journal_mode` and `:busy_timeout` as it sets them for the notebook repo. Its
  `:pool_size` must be at least 2: the `Ecto.Migrator` child runs the
  migrations inside a `Task`, which needs a connection beside the one the
  starting process holds, and at 1 the application never starts. It loads no
  sqlite-vec extension: nothing it holds is a vector.

  Its first table is the registry `YmerNode.References` serves. Until registry
  sync lands, that registry is the only copy of every reference added on this
  node — a reference is cheap to re-add and nothing here is precious, but the
  operator is told so plainly in `README.md`'s layout section rather than left
  to infer it from the backup's silence.
  """
  use Ecto.Repo, otp_app: :ymer_node, adapter: Ecto.Adapters.SQLite3
end
