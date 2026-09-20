defmodule YmerNode.Notebook.Repo do
  @moduledoc """
  Ecto repo for `notebook.db` — the node's one deliberate local store.

  This repo owns **no** schema: the LLM creates and evolves tables at runtime
  through the `notebook` MCP tool. There are no `Ecto.Schema` modules and no
  migrations, and this repo is deliberately absent from `:ecto_repos` — which
  lists `YmerNode.Repo` alone — so `mix ecto.*` never manages this file. Adding
  it to that list is what must never happen: it would put `mix ecto.drop` one
  keystroke from the one file the durability rule (`YmerNode`) exists for. The
  repo exists to give `YmerNode.Notebook` a supervised connection pool and to
  load the sqlite-vec `vec0` extension on every connection.

  On a fresh store those connections race each other to set the journal mode, and
  the first boot logs `database is locked` once. It is expected and is not fixed;
  `README.md`'s layout section documents it for the operator who meets it in a
  container log.

  ## Why the schema is not ours

  Everything else the node serves is rebuildable: lose it and a resync or a
  reinstall restores it. `notebook.db` is the exception — it holds curated
  knowledge the user and the LLM govern between them, so the node's obligation
  is durability (`YmerNode.Notebook.Backup`), never schema authority. A repo
  that shipped migrations would claim the second.

  ## Extension loading

  The repo's init callback injects `:load_extensions` at boot rather than from
  config files, because the arch-specific absolute path resolves correctly in
  dev, test, and a release only once `:ymer_node` is loaded — which is true at
  repo start but not during compile-time config evaluation. `exqlite` disables
  the SQL-level `load_extension()` function after loading `vec0`, so callers
  cannot load further extensions.

  The load is **best-effort and silent**: exqlite's extension loader runs
  `SELECT load_extension(...)` and discards the result, so a missing, corrupt, or
  wrong-arch binary would otherwise boot a healthy-looking repo with `vec0` absent,
  failing only later as `no such module: vec0`. Two guards close that gap: the
  init callback `File.exists?`-checks the resolved, arch-suffixed binary and
  raises if absent (and the arch resolver raises for an unvendored arch), and
  `YmerNode.Notebook.VecLoadCheck` asserts `SELECT vec_version()` at boot
  wherever it is enabled.
  """
  use Ecto.Repo, otp_app: :ymer_node, adapter: Ecto.Adapters.SQLite3

  alias DBConnection.ConnectionError

  # The measurements behind the budget — `await_running/0`'s doc states the
  # decision they support. The lock's supervised restart: 2-54 µs over 200
  # kills. This repo's own, from its name being registered again to Ecto
  # holding its metadata: a median of 92 µs and a maximum of 4.1 ms over 200
  # kills. The pool's reconnect backoff: one second at its first tick, growing
  # toward thirty. The budget is an order of magnitude above the widest window
  # seen and orders of magnitude below the backoff.
  @restart_wait_ms 50
  @restart_poll_ms 5

  # The modes SQLite accepts, as `config/runtime.exs` already bounds them. The
  # restore interpolates the atom into a `PRAGMA`, so the read refuses anything
  # outside this list rather than hand an unbounded value to SQL — and the
  # guard below carries the same bound to the function that interpolates.
  @journal_modes [:wal, :delete, :truncate, :persist, :memory, :off]

  @doc """
  Whether `mode` is one of the journal modes SQLite accepts — the bound
  `journal_mode/0` enforces, as a guard, so the function that interpolates a
  mode into a `PRAGMA` refuses anything else at its own head rather than
  trusting its caller to have read the configuration. SQLite treats an
  unrecognised journal-mode value as a no-op that answers the current mode,
  so nothing downstream would refuse it.
  """
  defguard is_journal_mode(mode) when mode in @journal_modes

  # ─── Runtime configuration ──────────────────────────────────────────

  @doc """
  The configured path of `notebook.db`, read straight from the application
  environment.

  `YmerNode.Notebook.Backup` reads this at the start of a restore — after the id
  resolves and before the safety capture — and carries the value into the down
  window, where the repo child is deliberately **stopped** to swap the file
  underneath it. `config/0` would answer too (it is a pure read plus the `init/2`
  callback), but that callback runs `vec0_path/0`'s filesystem checks and can
  raise — machinery a restore has no use for. This read is deliberately thinner,
  and owning it here keeps the value's single owner the module it describes,
  instead of a second `Application.get_env` in the caller.
  """
  def database_path do
    :ymer_node
    |> Application.get_env(__MODULE__, [])
    |> Keyword.fetch!(:database)
  end

  @doc """
  The journal mode the pool is configured for — `:journal_mode` in the repo's
  application environment, `:wal` when unset, which is the adapter's own default.

  `YmerNode.Notebook.Backup` switches a restored copy to this mode before the
  pool sees it, so the pool's first connections meet a file already in the mode
  they will set and have nothing to convert. Reading it here keeps the value's
  single owner the module it describes, the same reason `database_path/0` exists.
  Raises `ArgumentError` for a value outside the modes SQLite accepts, so an
  unbounded value never reaches a `PRAGMA`.
  """
  def journal_mode do
    mode =
      :ymer_node
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:journal_mode, :wal)

    if is_journal_mode(mode) do
      mode
    else
      raise ArgumentError, "invalid :journal_mode for #{inspect(__MODULE__)}: #{inspect(mode)}"
    end
  end

  # ─── Public API ─────────────────────────────────────────────────────

  @doc """
  Whether the repo can take a query right now as a matter of process state —
  the **liveness** half of what a caller wants to know, and only that half.

  A **structural** read, and a two-part one: the name the supervisor registers
  this repo under must resolve, and Ecto must hold the repo's adapter metadata,
  which it records only once the repo's start has finished. `Ecto.Adapter.lookup_meta/1`
  answers both at once — it is the first thing every query resolves — and any
  failure to resolve is the answer; the message it may carry is never read. That
  text belongs to a dependency and is free to change: a check that read it would
  keep passing until the day the wording moved, and then quietly report a
  stopped notebook as running.

  Registration alone is not enough, and measured so. A named repo's process is
  registered before its `init/1` runs, and Ecto writes its metadata after the
  connection pool has started, so a read of the name alone admits a window —
  a median of 92 µs and up to 4.1 ms over 200 supervised restarts — in which
  every query raises a raw `ArgumentError` out of the registry. `all_running/0`
  cannot close it either: the entry a dead repo left behind still names this
  module for a moment, and did so in 46 of those 200 restarts. Resolving the
  metadata for the pid the name points at is what makes the read exact.

  It answers whether the process is there, never whether the store behind it can
  be opened: a repo restarted onto a store it cannot open is registered and not
  serving, and `not_serving?/1` is the half that says so. `YmerNode.Notebook`'s
  moduledoc owns how the two combine into one answer.

  Three modules read it, and one wait stands behind two of them.
  `YmerNode.Notebook` reads it at the pre-check and again in the catch, because a
  SQL call takes no lock and can land anywhere inside another operation's down
  window; unless a restore's hold already explains the stop, a `false` from
  either goes on to `await_running/0` below, so a repo inside a supervised
  restart is served rather than reported. `YmerNode.Notebook.Backup` calls
  `await_running/0` outright before a capture, whose `VACUUM INTO` has nothing to
  read from a stopped repo — there the wait's own loop is what reads this
  function. And the test helper reads it once at boot, to put the sandbox in
  manual mode only when the repo started.

  One read inside the guard does not wait, deliberately — the classification of
  a retry's own failure; `YmerNode.Notebook`'s moduledoc owns that rule.
  """
  def running? do
    _meta = Ecto.Adapter.lookup_meta(__MODULE__)
    true
  rescue
    _not_resolvable -> false
  end

  @doc """
  `running?/0` after a bounded wait: `true` as soon as the repo can take a query,
  `false` when it still cannot at the end of the budget.

  A supervised restart of the repo lasts microseconds to a few milliseconds,
  and the pool's reconnect backoff starts at a second: the budget sits an order
  of magnitude above the first and well below the second, so a caller that
  lands in a restart is served rather than told the notebook is down, and a
  store the pool cannot open is never waited on. This is the one wait the node
  performs for a stopped repo. Polled, not subscribed, because the supervisor
  offers nothing to subscribe to and the poll is a microsecond read.
  `YmerNode.Notebook`'s moduledoc owns how the answer combines with the rest.
  """
  def await_running do
    await_running(System.monotonic_time(:millisecond) + @restart_wait_ms)
  end

  @doc """
  Whether `failure` is the pool's own report that it could not provide a
  connection — the **serving** half, and what "registered, and the store cannot
  be opened" looks like from a call site.

  The read is structural, like `running?/0`'s: it matches
  `DBConnection.ConnectionError`'s documented type and its documented `reason`
  field, never the message string, which belongs to a dependency and is free to
  change. `:queue_timeout` is set at exactly the two places the pool drops a
  request from its queue, both before any connection is handed out — so a client
  that timed out while holding a connection it did get, which is a slow
  statement and not a store that will not open, can never wear it. An
  `Exqlite.Error` — a malformed page, a SQL fault — is not this and stays a
  fault.

  Three arrival shapes, because the same fact reaches three call sites
  differently: raised bare out of `transaction/1` or `checkout/2`, wrapped in a
  `{:badmatch, …}` by an `{:ok, _} =` match on `query/2`'s answer, and returned
  as `query/2`'s own error tuple. The middle one is the raw term a `catch` clause
  is handed; `rescue` would normalise it to a `MatchError` struct, and the guard
  that reads this uses `catch`, because it has exits to contain as well.

  One over-approximation the node accepts: the pool answers the same way when
  every connection is merely busy for longer than its queue window. This node
  serves one client on loopback over short statements, so saturation is not a
  live cause of it.
  """
  def not_serving?(%ConnectionError{reason: :queue_timeout}), do: true
  def not_serving?({:error, %ConnectionError{reason: :queue_timeout}}), do: true

  def not_serving?({:badmatch, {:error, %ConnectionError{reason: :queue_timeout}}}),
    do: true

  def not_serving?(_failure), do: false

  # ─── Callbacks ──────────────────────────────────────────────────────

  @impl true
  def init(_context, config) do
    {:ok, Keyword.put_new(config, :load_extensions, [vec0_path()])}
  end

  # Absolute path to the vendored, arch-matched sqlite-vec loadable. The `.so`/
  # `.dylib` suffix is appended by SQLite's loader, so the INJECTED path is
  # suffix-less — but the existence check needs the real (suffixed) file. Raising
  # here (init/2 evaluates this eagerly) converts exqlite's silent, discarded load
  # failure into a clear boot error for the missing-binary / unvendored-arch case.
  defp vec0_path do
    path = Application.app_dir(:ymer_node, Path.join(["priv", "sqlite", arch_dir(), "vec0"]))

    unless File.exists?(path <> loadable_suffix()) do
      raise "notebook.db: no sqlite-vec binary for arch #{arch_dir()} at " <>
              "#{path}#{loadable_suffix()} — vendor it under priv/sqlite/#{arch_dir()}/"
    end

    path
  end

  defp loadable_suffix do
    case :os.type() do
      {:unix, :darwin} -> ".dylib"
      {:unix, _} -> ".so"
    end
  end

  # The vendored arches are darwin-arm64, linux-x86_64, linux-aarch64.
  # Anything else — notably an Intel Mac's darwin-x86_64, which is not a target —
  # raises rather than naming a binary that was never committed, so an unsupported
  # host fails loudly at repo init instead of with an opaque load error later.
  defp arch_dir do
    arch = to_string(:erlang.system_info(:system_architecture))

    case :os.type() do
      {:unix, :darwin} ->
        if String.contains?(arch, ["arm", "aarch"]) do
          "darwin-arm64"
        else
          raise "notebook.db: no vendored sqlite-vec binary for darwin/#{arch}; " <>
                  "vendored only for darwin-arm64, linux-x86_64, linux-aarch64"
        end

      {:unix, _} ->
        if String.contains?(arch, ["aarch", "arm"]), do: "linux-aarch64", else: "linux-x86_64"
    end
  end

  # The wait keys on a monotonic deadline rather than on the sleeps it has taken,
  # so the read's own cost — nothing here, but the same shape guards a poll that
  # can block — never stretches the budget.
  defp await_running(deadline) do
    cond do
      running?() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(@restart_poll_ms)
        await_running(deadline)
    end
  end
end
