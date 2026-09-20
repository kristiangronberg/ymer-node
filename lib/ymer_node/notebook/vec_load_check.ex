defmodule YmerNode.Notebook.VecLoadCheck do
  @moduledoc """
  One-shot boot probe that aborts application start when the sqlite-vec `vec0`
  extension did not load into `YmerNode.Notebook.Repo`.

  exqlite loads extensions best-effort — its extension loader runs
  `SELECT load_extension(...)` and DISCARDS the result, so a missing, corrupt, or
  wrong-arch binary boots a healthy-looking repo with `vec0` silently absent. The
  failure would otherwise surface much later as `no such module: vec0` at the MCP
  boundary, with the SQL loader already disabled and no way to recover. This child
  runs `SELECT vec_version()` once: on success it logs the version and returns
  `:ignore`, so the supervisor keeps no process; on failure it raises, which
  aborts `Supervisor.start_link` and fails the boot.

  Refusing to boot is the right trade for a node whose vector layer is a headline
  capability. An install that silently cannot do KNN search is worse than one that
  says why it stopped — and what it says has to be true, because this is the last
  answer the node gives about a notebook it cannot use, and the one the operator
  reads after a not-serving answer sends them to the log. The one query here fails
  the same way for a store that will not open as for an extension that did not
  load, so the two are told apart before the message is written: see `refusal/1`.

  Disabling is a configuration decision, not an environment sniff, because the
  reason to skip the probe is a property of the test setup rather than of the
  host: the `Ecto.Adapters.SQL.Sandbox` holds no checked-out connection at boot,
  so the probe would fail against a perfectly healthy build. The disabled branch
  lives inside `init/1` and returns the same `:ignore` the success path does,
  which is what lets the supervision tree list this child unconditionally.
  """
  use GenServer

  alias YmerNode.Notebook.Repo

  require Logger

  # ─── Runtime configuration ──────────────────────────────────────────

  @doc "Whether the probe runs at boot. Defaults to enabled — a skipped check is opt-in."
  def enabled? do
    :ymer_node
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:enabled, true)
  end

  # ─── Public API ─────────────────────────────────────────────────────

  def start_link(opts) when is_list(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(_opts) do
    if enabled?(), do: probe(), else: :ignore
  end

  # ─── Private ────────────────────────────────────────────────────────

  defp probe do
    case Repo.query("SELECT vec_version()") do
      {:ok, %{rows: [[version]]}} ->
        Logger.info("sqlite-vec loaded into notebook.db (#{version})")
        :ignore

      other ->
        raise refusal(other)
    end
  end

  # Two different failures wear the same shape at this call, and the operator
  # reads one line in the container log. A pool that could not provide a
  # connection means the node never opened the store at all, so vec0 never got the
  # chance to answer — reporting that as a vec0 load failure sends the operator
  # hunting a vendored binary while their store sits unopenable.
  #
  # The store message names the path deliberately. This string is an operator's
  # surface — a boot log line, never a caller's answer — so the path-opacity rule
  # every MCP-reachable failure follows does not apply to it, and the operator who
  # has to go and look at the file needs to know which one.
  defp refusal(other) do
    if Repo.not_serving?(other),
      do:
        "notebook.db: the node cannot open its store at #{Repo.database_path()} — " <>
          "`SELECT vec_version()` returned #{inspect(other)}. The file is unreadable, " <>
          "or it is not a database. Refusing to boot.",
      else:
        "notebook.db: sqlite-vec vec0 failed to load — `SELECT vec_version()` " <>
          "returned #{inspect(other)}. The vendored binary is missing, corrupt, " <>
          "or the wrong arch/ABI for this host. " <>
          "Vector search is unavailable; refusing to boot."
  end
end
