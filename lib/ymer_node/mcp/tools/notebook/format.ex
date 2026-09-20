defmodule YmerNode.Mcp.Tools.Notebook.Format do
  @moduledoc """
  Shapes `YmerNode.Notebook` and `YmerNode.Notebook.Backup` results into
  JSON-serialisable maps for MCP responses.
  Query results pass through as parallel `columns`/`rows` arrays (compact and
  order-preserving) rather than per-row maps.
  """

  def query_result(%{columns: columns, rows: rows}), do: %{columns: columns, rows: rows}
  def execute_result(%{affected_rows: n}), do: %{affected_rows: n}
  def tables(list) when is_list(list), do: %{count: length(list), tables: list}
  def schema(map) when is_map(map), do: map

  def backup(entry) when is_map(entry), do: entry

  def backups(list) when is_list(list), do: %{count: length(list), backups: list}

  @doc """
  Shapes a completed restore. The note is the caller's only warning that the undo
  anchor is itself perishable — it counts against retention like any other backup,
  so a caller who waits long enough loses the ability to undo the undo.
  """
  def restore(%{restored: restored, safety_backup: safety}),
    do: %{
      restored: restored,
      safety_backup: safety,
      note:
        "Rolled back. A backup of the previous state was saved as id #{safety} — restore " <>
          "it to undo. It counts against the retention limit like any other backup, so it " <>
          "will be pruned in turn: undo soon rather than later."
    }
end
