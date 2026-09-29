defmodule YmerNode.References.Cache.Reconcile do
  @moduledoc """
  The boot step that makes the cache directory rebuildable with the node
  database: it runs `YmerNode.References.Cache.reconcile/0` once, after the
  migrator and before anything can fill an entry, and leaves no process
  behind.

  A fresh node database names no file, so the directory empties; a run cut
  short leaves a `.part` file no entry names, and that goes too; an entry whose
  file is gone goes as well. Only files carrying the node's own naming are ever
  removed.

  A reconcile that fails — an unwritable or missing mount, a directory that is
  a file — is logged and the boot goes on: the cache is rebuildable and the
  notebook and the registry are not, so they never stay down over it.
  """

  alias YmerNode.References.Cache

  require Logger

  # ─── Runtime configuration ──────────────────────────────────────────

  @doc """
  Whether the boot runs the reconcile
  (`config :ymer_node, YmerNode.References.Cache.Reconcile, :enabled`).

  Defaults to enabled. `config/test.exs` turns it off for the reason the
  loader's boot compile is off there: at application start the sandbox holds no
  checked-out connection, so the read of the entries would fail against a
  healthy build. `YmerNode.References.CacheTest` calls the reconcile itself.
  """
  def enabled? do
    :ymer_node
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:enabled, true)
  end

  # ─── Public API ─────────────────────────────────────────────────────

  @doc false
  def child_spec(_options), do: %{id: __MODULE__, start: {__MODULE__, :start_link, []}}

  @doc """
  Runs the reconcile when enabled, then answers `:ignore`, like `Ecto.Migrator` —
  after a failed reconcile too, which it logs.
  """
  def start_link do
    if enabled?(), do: reconcile()
    :ignore
  end

  defp reconcile do
    Cache.reconcile()
  rescue
    exception ->
      Logger.error(
        "cache: could not reconcile the cache directory: #{Exception.message(exception)}"
      )
  end
end
