import Config

# Executed for every environment, including inside a release: after compilation
# and before the system starts. Nothing here is compile-time configuration.

# A blank environment variable is TRUTHY in Elixir ("" != nil), so `System.get_env/1`
# and `||` both treat `PORT=` as a value. Left alone that turns an empty variable
# into `String.to_integer("")` — an ArgumentError that kills boot — or, for a path,
# into `File.mkdir_p!("")`. Whitespace padding survives the quoted delivery forms
# (`docker run -e PORT="8012 "`, quoted .env values) and would crash the integer
# reads the same way — or worse, make a padded journal-mode value silently fall
# to its default. Normalise once, here — blank and padding both — and read
# through this everywhere below.
env = fn name ->
  case System.get_env(name) do
    nil ->
      nil

    value ->
      case String.trim(value) do
        "" -> nil
        trimmed -> trimmed
      end
  end
end

# A bad integer in the environment must name what to fix. `String.to_integer/1`
# raises about its own argument — "not a textual representation of an integer" —
# and says neither which variable carried the value nor what the container was
# started with, which is the whole of what an operator reading a boot crash
# needs. The parse must consume the value WHOLE: a `POOL_SIZE=5x` that silently
# became 5 would be worse than a refusal. A blank or all-whitespace value never
# reaches the parse — `env` above turns it into nil — so the default stands; a
# padded value is trimmed there rather than voided, so `POOL_SIZE=" 8 "` reads 8.
integer_env = fn name, default ->
  case env.(name) do
    nil ->
      default

    value ->
      case Integer.parse(value) do
        {number, ""} -> number
        _ -> raise ArgumentError, "#{name} must be an integer; got #{inspect(value)}"
      end
  end
end

if config_env() == :prod do
  # One directory holds the node's databases, and the operator names the
  # directory rather than either file — the file names are fixed inside it.
  # ecto_sqlite3 creates a database file on first connection, so only the
  # directory has to exist; the explicit mkdir is what turns an unwritable path
  # into a named failure at boot rather than an :eacces crash-loop later.
  databases_path = env.("DATABASES_PATH") || "/data/db"
  File.mkdir_p!(databases_path)

  # The files directory — the one directory a script reads files from and
  # writes files to, answered by `YmerNode.Script.Context.files_dir/1`. A
  # sibling of db/ and backups/ under the mount, never inside either: it is the
  # user's, the node never backs it up, and a deploy's recreate keeps the mount
  # whole. Created here at boot the way db/ is, so an unwritable path is the
  # boot log's first line rather than a File.Error inside some script's run.
  # Read through `env`: a padded path names a directory nobody meant, where TZ
  # below is read verbatim because libc reads it so. Expanded, unlike the node's
  # own two paths above and below: this is the one path handed to scripts, and
  # `files_dir/1` promises them an absolute one — `Path.expand/1` is the
  # identity on every absolute value, so the compose file's default is as it
  # reads, and a relative value resolves against the release's own cwd here,
  # once, rather than inside every script that joins a name onto it.
  files_dir = Path.expand(env.("FILES_PATH") || "/data/files")
  File.mkdir_p!(files_dir)
  config :ymer_node, YmerNode.Script.Context, files_dir: files_dir

  # Map the journal-mode env to a known atom WITHOUT String.to_atom — it bounds the
  # value to the modes SQLite actually accepts. (`Credo.Check.Warning.UnsafeToAtom`
  # is disabled in .credo.exs, so nothing would stop the unsafe conversion; this is
  # a deliberate choice, not a lint being obeyed.)
  journal_mode =
    case env.("NODE_DB_JOURNAL_MODE") do
      "truncate" -> :truncate
      "delete" -> :delete
      "persist" -> :persist
      "memory" -> :memory
      "off" -> :off
      _ -> :wal
    end

  config :ymer_node, YmerNode.Notebook.Repo,
    database: Path.join(databases_path, "notebook.db"),
    pool_size: integer_env.("POOL_SIZE", 5),
    journal_mode: journal_mode,
    busy_timeout: integer_env.("NODE_DB_BUSY_TIMEOUT", 5000)

  # The node database sits beside the store and follows the same journal mode
  # and busy timeout: the NODE_DB_ variables govern the node's databases, both
  # of them. Its pool is deliberately not POOL_SIZE's — that variable sizes the
  # notebook's open SQL surface, where a caller's statement can be long-running,
  # while this pool serves short registry reads and the migrator child that runs
  # at every boot. It is sized here rather than left to the adapter so the
  # migrator's own task always has a connection beside the starting process.
  config :ymer_node, YmerNode.Repo,
    database: Path.join(databases_path, "node.db"),
    pool_size: 5,
    journal_mode: journal_mode,
    busy_timeout: integer_env.("NODE_DB_BUSY_TIMEOUT", 5000)

  # Backups are a top-level sibling of db/ under the mount, NOT inside it, so
  # they survive a deploy and sit beside the other user-facing directories.
  # BACKUPS_RETAIN caps how many are kept; the oldest are pruned after each
  # successful capture.
  config :ymer_node, YmerNode.Notebook.Backup,
    directory: env.("BACKUPS_PATH") || "/data/backups",
    retain: integer_env.("BACKUPS_RETAIN", 40)

  # The secrets file, which `config/prod.exs` already places at
  # /data/secrets.env. This only moves it — an install that keeps its secrets
  # somewhere else on the mount says so here. The node creates the file 0600 at
  # the first `secrets set` and refuses to read one any group or other bit can
  # reach, so pointing this at a shared path is refused rather than obeyed.
  if secrets_path = env.("SECRETS_PATH") do
    config :ymer_node, YmerNode.Secrets, path: secrets_path
  end

  # Inside the prod guard, not beside it. The container is the only deployment that
  # sets PORT, while dev and test carry deliberate compile-time values — test.exs
  # binds port 0 precisely so partitioned runs cannot collide. Read unconditionally,
  # a PORT exported in the developer's shell (or by a sibling project) silently
  # overrode both, and `Keyword.fetch!` could not tell: the key is present, just wrong.
  # No default, deliberately: unset means the compile-time port stands, which
  # `integer_env` says by answering nil — and a PORT that is set but not a number
  # still refuses boot rather than falling back to one.
  if port = integer_env.("PORT", nil) do
    config :ymer_node, YmerNode.Mcp, port: port
  end

  # The node's time zone, read from the platform's own variable — the one
  # setting the container's clock reads too. Read VERBATIM, past `env`'s trim:
  # libc reads TZ verbatim, so a padded name trimmed into a known zone would
  # boot a node whose scripts answer that zone while its clock and the time on
  # its own log lines keep UTC. `env` still decides set-or-blank; the value
  # itself is taken as delivered, and a padded name is one the database does
  # not know, refused below like any other.
  # Inside the prod guard for PORT's reason: TZ is a variable developers export,
  # and read unconditionally a shell's value would silently change the zone a
  # dev node or a test run answers. Unset or blank writes nothing, and
  # `YmerNode.Script.Context.time_zone/1` answers Etc/UTC. A set name is checked
  # against the release's zone database here, before the system starts: a POSIX
  # TZ string, a lowercase name, a typo or a padded name refuses boot naming TZ
  # and the value, so a running node's zone is always one every script's
  # `DateTime` accepts.
  if env.("TZ") do
    time_zone = System.get_env("TZ")

    case DateTime.now(time_zone, Tz.TimeZoneDatabase) do
      {:ok, _now} ->
        config :ymer_node, YmerNode.Script.Context, time_zone: time_zone

      {:error, _reason} ->
        raise ArgumentError,
              "TZ must be an IANA time zone name this release knows, such as " <>
                "\"Europe/Helsinki\"; got #{inspect(time_zone)}"
    end
  end

  # The bind marker: an empty file the node's own image writes at build. Its
  # presence — and nothing else — widens the bind to all interfaces, which a
  # container needs because a process bound to loopback inside one is unreachable
  # through a published port. It sits outside the release directory on purpose, so
  # copying the release out of the image cannot carry it: a release started outside
  # that image finds no marker and binds loopback, and nothing set at `docker run`
  # time can widen it. The rule and what it costs live in `YmerNode.Mcp`'s
  # "Loopback is the security model" section.
  if File.exists?("/etc/ymer-node/bind-all-interfaces") do
    config :ymer_node, YmerNode.Mcp, ip: {0, 0, 0, 0}
  end

  # The node's wire identity, and the reason a deploy can prove a container
  # is running the code it just built. The image stamps the revision it was
  # built from into YMER_NODE_REVISION (the Dockerfile does it), and the
  # release's own start script exports RELEASE_VSN before this file is
  # evaluated, so the two compose `<version>+<revision>` — semver build
  # metadata naming the exact commit this container carries.
  # `config/config.exs` sets the bare version at compile time; this
  # overrides it at boot.
  #
  # A build that could not name a revision leaves the variable blank, the
  # normaliser above turns that into nil, and the bare version stands. Read
  # through that normaliser rather than System.get_env/1 for exactly that
  # reason: an empty variable is truthy, and a version ending in a bare `+`
  # would name nothing.
  #
  # `mix ymer_node.deploy` composes the same string from the version and
  # revision it built and compares it against what the container answers on
  # `initialize`. That comparison is what keeps this composition and the
  # task's expectation equal — change one and the verify fails loudly
  # rather than drifting.
  revision = env.("YMER_NODE_REVISION")
  release_version = env.("RELEASE_VSN")

  if revision && release_version do
    config :wymcp, version: "#{release_version}+#{revision}"
  end
end
