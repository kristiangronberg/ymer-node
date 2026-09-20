defmodule YmerNode.Mcp.Tools.Notebook do
  @moduledoc """
  Wymcp tool `notebook` — an open SQL surface over `notebook.db`, the node's own
  private store, together with the actions that keep it safe.

  The store's schema belongs to the user and the LLM: this tool runs whatever SQL
  it is handed. The only things it refuses are the two that would break the
  contract around it — reaching outside this database, and letting a read write.
  Delegates to `YmerNode.Notebook` and `YmerNode.Notebook.Backup`.

  Backup lives on this tool rather than beside it because the node has exactly one
  database worth keeping: "back up" and "back up the notebook" are the same act,
  and a caller who has just been told the store is destructible should find the
  undo in the same place.

  Destructive — `DROP`, `DELETE` and `restore` are all reachable — and
  closed-world, since everything it touches is a local file.
  """
  use Wymcp.Tool

  alias YmerNode.Mcp.Tools.Notebook.{Actions, Errors, Schemas}
  alias YmerNode.Mcp.Tools.Notebook.Hints, as: NotebookHints

  @impl true
  def name, do: "notebook"

  @impl true
  def title, do: "Notebook"

  @impl true
  def annotations, do: %{"destructiveHint" => true, "openWorldHint" => false}

  @impl true
  def description,
    do:
      "Open SQL over your own notebook (notebook.db) — a private store on this machine: " <>
        "create and evolve your own tables, keep documents with sqlite-vec vector embeddings, " <>
        "and run KNN search. execute = writes/DDL, query = read-only SELECT. The same tool " <>
        "keeps the store: create takes a backup, list shows them, restore rolls one back. " <>
        "Back up before anything destructive. Call help {tool: \"notebook\"} for the vec0 + " <>
        "INTEGER-PRIMARY-KEY usage guide."

  @impl true
  def actions, do: Schemas.all()

  @impl true
  def run_action(action, data, _ctx), do: Actions.run(action, data)

  @impl true
  def hints(action, hint_context), do: NotebookHints.for(action, hint_context)

  @impl true
  def handle_error({reason, ctx}) when is_map(ctx), do: Errors.format(reason, ctx)
  def handle_error(reason), do: Errors.format(reason)
end
