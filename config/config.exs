import Config

# `YmerNode.Repo` owns its schema — the migrations under priv/repo are this
# codebase's — so `mix ecto.*` may manage it. `YmerNode.Notebook.Repo` is
# deliberately absent. It owns no schema and no migrations — the LLM creates and
# evolves its tables at runtime through the notebook tool — so no mix task may
# ever migrate or drop it. Listing exactly one of the two repos is what holds
# that invariant mechanically rather than by convention.
config :ymer_node, ecto_repos: [YmerNode.Repo]

# The node database's array columns (`tags`) are stored as JSON text, and the
# adapter encodes and decodes them through the library named here. Elixir's own
# `JSON` module is the choice because it is in every release by construction:
# the adapter's default, Jason, is no dependency of this project — it reaches
# dev and test only through mix_audit and credo — so a release built without it
# fails every insert of a tags value while the whole suite stays green
# (measured 2026-09-09, on the first deploy after the references registry).
config :ecto_sqlite3, json_library: JSON

# The one line that makes zones work in every script. Elixir's own database
# knows only UTC, and no script can install another — the database is one
# setting for the whole VM — so the node sets tz's, once, for every run.
config :elixir, :time_zone_database, Tz.TimeZoneDatabase

# The node's wire identity, read by the MCP framework.
config :wymcp,
  name: "ymer-node",
  version: Mix.Project.config()[:version]

# The metadata keys the MCP framework puts on its log lines — the line table
# in `Wymcp.Telemetry.Logger`'s moduledoc, copied whole. Listing them here is
# what makes them appear in the node's own logs; a key missing here is
# silently dropped from every line.
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [
    :message_id,
    :method,
    :http_method,
    :rejecter,
    :reason,
    :status,
    :message,
    :tool_name,
    :action,
    :is_error,
    :error_kind,
    :result_type,
    :duration_ms,
    :exception,
    :error,
    :auth_module,
    :crash_reason
  ]

import_config "#{config_env()}.exs"
