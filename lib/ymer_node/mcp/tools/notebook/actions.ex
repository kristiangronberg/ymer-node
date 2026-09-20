defmodule YmerNode.Mcp.Tools.Notebook.Actions do
  @moduledoc """
  Action implementations for the `notebook` MCP tool
  (`YmerNode.Mcp.Tools.Notebook`, which calls `run/2`) — a thin boundary over
  `YmerNode.Notebook` and `YmerNode.Notebook.Backup`. This is a trust boundary:
  `sql`, `table` and `id` are guarded `is_binary` in each head because nothing
  downstream validates them — the MCP dispatch layer checks that a parameter is
  present but never what type it holds — so `sql` and `table` flow straight into
  SQLite and `id` flows into filename construction. Each action returns
  `{:ok, data, hint_ctx}` or `{:error, {reason, ctx}}` — and, where the error is one
  the caller can act on, `{:error, {reason, ctx}, hint_ctx}`, the three-element form
  that puts a follow-up hint on the error payload rather than only in its prose.

  A wrong-typed value used to match no head at all and crash into the framework's
  top-level rescue, which told the caller only that a function clause did not
  match. Each guarded head now has an unguarded twin at the bottom of the module
  that answers `{:wrong_type, …}` instead, naming the key, the type wanted and
  what arrived. The guard is still what keeps the bad value out of SQLite and out
  of filename construction; the twin only makes the refusal readable.
  """
  alias YmerNode.Mcp.Tools.Helpers
  alias YmerNode.Mcp.Tools.Notebook.Format
  alias YmerNode.Notebook
  alias YmerNode.Notebook.Backup

  def run(:execute, %{"sql" => sql}) when is_binary(sql) do
    ctx = %{action_verb: "execute SQL"}

    case Notebook.execute(sql) do
      {:ok, result} -> {:ok, Format.execute_result(result), %{action: :execute}}
      {:error, reason} -> {:error, {reason, ctx}}
    end
  end

  def run(:query, %{"sql" => sql}) when is_binary(sql) do
    ctx = %{action_verb: "run query"}

    case Notebook.query(sql) do
      {:ok, result} -> {:ok, Format.query_result(result), %{}}
      {:error, reason} -> {:error, {reason, ctx}}
    end
  end

  def run(:tables, _data) do
    case Notebook.tables() do
      {:error, reason} -> {:error, {reason, %{action_verb: "list tables"}}}
      list -> {:ok, Format.tables(list), %{}}
    end
  end

  def run(:schema, %{"table" => table}) when is_binary(table) do
    ctx = %{action_verb: "read schema"}

    case Notebook.table_schema(table) do
      {:ok, result} -> {:ok, Format.schema(result), %{}}
      {:error, reason} -> {:error, {reason, ctx}}
    end
  end

  def run(:create, _data) do
    case Backup.create() do
      {:ok, entry} -> {:ok, Format.backup(entry), %{action: :create}}
      {:error, reason} -> {:error, {reason, %{action_verb: "take a backup"}}}
    end
  end

  def run(:list, _data) do
    case Backup.list() do
      {:error, reason} -> {:error, {reason, %{action_verb: "list backups"}}}
      list -> {:ok, Format.backups(list), %{}}
    end
  end

  def run(:restore, %{"id" => id}) when is_binary(id) do
    ctx = %{action_verb: "restore the notebook"}

    case Backup.restore(id) do
      {:ok, result} ->
        {:ok, Format.restore(result), %{action: :restore}}

      {:error, {:restore_incomplete, %{safety_backup: safety}} = reason} ->
        {:error, {reason, ctx}, %{action: :restore, recover: safety}}

      # Two ways in: a copy that failed before the live database was overwritten,
      # and a repo the supervisor could not stop — the second needs an absent child
      # spec, which the safety capture refuses first, so it is a contract rather
      # than a live path. Both leave the notebook untouched, which is what makes
      # repeating the same call the safe next step and the id the hint's example.
      {:error, {:restore_not_started, _detail} = reason} ->
        {:error, {reason, ctx}, %{action: :restore, retry: id}}

      {:error, reason} ->
        {:error, {reason, ctx}}
    end
  end

  # The wrong-typed twins, kept together because they are one rule rather than
  # four decisions. The framework's dispatch gate answers an absent key with the
  # action's own input schema, and its merge keeps a `null` the caller sent — so
  # what reaches a twin is always a present key holding the wrong type, which is a
  # mistake the caller can fix from the message alone. Grouped after the guarded
  # heads, never before them: a twin that ran first would swallow every good call.
  def run(:execute, %{"sql" => sql}),
    do: Helpers.wrong_type("sql", "a string", sql, "execute SQL")

  def run(:query, %{"sql" => sql}), do: Helpers.wrong_type("sql", "a string", sql, "run query")

  def run(:schema, %{"table" => table}),
    do: Helpers.wrong_type("table", "a string", table, "read schema")

  def run(:restore, %{"id" => id}),
    do: Helpers.wrong_type("id", "a string", id, "restore the notebook")
end
