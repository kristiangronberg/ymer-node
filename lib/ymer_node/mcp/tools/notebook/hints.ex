defmodule YmerNode.Mcp.Tools.Notebook.Hints do
  @moduledoc """
  Follow-up hints for the `notebook` tool, keyed off the hint_context maps
  `YmerNode.Mcp.Tools.Notebook.Actions` produces. After `execute` creates schema, the
  natural next steps are describing or querying it; after a capture the natural
  next step is confirming it. A completed restore needs no follow-up either, since
  the roll-back is already done — but a restore that failed recoverably does: the
  hint carries the id of the backup to restore, or of the restore to retry, so the
  recovery is one call away instead of a re-read of the error text. Everything else
  falls through to none — including every answer about a notebook that cannot take
  the call, whose next action is a person's and not another tool call, and a
  backup that will not open, whose next action is a different id this module has
  no way to choose.
  """
  alias Wymcp.Hint

  def for(:execute, _ctx) do
    [
      Hint.new(
        tool: "notebook",
        action: "tables",
        description: "List tables to confirm the change",
        example: %{data: %{}}
      ),
      Hint.new(
        tool: "notebook",
        action: "query",
        description: "Read the data back",
        example: %{data: %{sql: "SELECT * FROM your_table LIMIT 20"}}
      )
    ]
  end

  def for(:create, _ctx) do
    [
      Hint.new(
        tool: "notebook",
        action: "list",
        description: "Confirm the backup was saved",
        example: %{data: %{}}
      )
    ]
  end

  def for(:restore, %{recover: safety_backup}) when is_binary(safety_backup) do
    [
      Hint.new(
        tool: "notebook",
        action: "restore",
        description: "Restore the backup taken just before this one to get the work back",
        example: %{data: %{id: safety_backup}}
      )
    ]
  end

  def for(:restore, %{retry: id}) when is_binary(id) do
    [
      Hint.new(
        tool: "notebook",
        action: "restore",
        description: "Retry the restore once — nothing was overwritten",
        example: %{data: %{id: id}}
      )
    ]
  end

  def for(_action, _ctx), do: []
end
