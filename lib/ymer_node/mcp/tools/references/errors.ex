defmodule YmerNode.Mcp.Tools.References.Errors do
  @moduledoc """
  Translates the `references` tool's error reasons, optionally with context,
  into messages a worker can act on. Called by
  `YmerNode.Mcp.Tools.References`'s `c:Wymcp.Tool.handle_error/1`.

  Every message names the next call rather than describing the fault, because
  the reader is an agent deciding what to do next and not a person reading a
  log.
  """

  alias YmerNode.Mcp.Tools.Helpers
  alias YmerNode.References.Sources

  def format(reason, ctx \\ %{}), do: message(reason, ctx)

  def message(%Ecto.Changeset{} = changeset, _ctx),
    do: Helpers.format_changeset_errors(changeset)

  def message(:not_found, _ctx), do: "Reference not found. Verify the id."
  def message(:invalid_id, _ctx), do: "Invalid reference id. Provide a positive integer id."

  def message(:empty_query, _ctx),
    do: "Search query cannot be empty. Provide free text, or omit it and filter instead."

  def message(:empty_find, _ctx),
    do:
      "find needs at least one criterion: a query, tags, or a source. " <>
        "Use `list` to browse the whole registry."

  def message(:invalid_tags, _ctx),
    do: "Invalid tags. Provide a JSON array of tag strings (e.g. [\"release\", \"notes\"])."

  # The vocabulary is never a module attribute: it grows and shrinks with the
  # accepted scripts, and a caller told the wrong list has no way to discover
  # the right one. It comes off the context where the action put it — the same
  # read the rest of that call used — and falls back to a fresh one only for a
  # caller that carried none, which is the `handle_error/1` path a bare reason
  # takes.
  def message(:invalid_source, %{declarations: declarations}) when is_list(declarations),
    do: "Invalid source. Valid: " <> Enum.join(Sources.vocabulary(declarations), ", ") <> "."

  def message(:invalid_source, _ctx),
    do: "Invalid source. Valid: " <> Enum.join(Sources.vocabulary(), ", ") <> "."

  def message(:invalid_limit, _ctx),
    do: "Invalid limit. Provide a positive integer (1–100)."

  def message(:invalid_offset, _ctx),
    do: "Invalid offset. Provide the line to start at, a positive integer from 1."

  def message(:invalid_lines, _ctx),
    do: "Invalid limit. Provide how many lines to read, a positive integer — or omit it."

  def message(:invalid_column, _ctx),
    do: "Invalid column. Provide the column a cut line's next names, a positive integer."

  def message(:invalid_cadence, _ctx),
    do: "Invalid cadence_minutes. Provide 5, 15, 30 or 60."

  def message(:invalid_hours, _ctx),
    do: "Invalid lifetime_hours. Provide a whole number of hours from 1 to 12."

  # The cache's refusals, and the runner's passed through it, arrive tagged
  # with a detail that already names the script and what happened.
  def message({:no_recipe, detail}, _ctx),
    do:
      "#{detail}. Follow its uri yourself, or accept a script that claims its host " <>
        "(or a web fallback) to have it fetched."

  def message({:not_cache_contract, detail}, _ctx),
    do:
      "#{detail}. The reference's pointer and its recipe still work — `get` shows " <>
        "the recipe; run it yourself. The script meets the cache when it answers " <>
        "content or unchanged (`scripts guide`, the section on a URL action and the cache)."

  def message({reason, detail}, _ctx) when is_atom(reason) and is_binary(detail),
    do: "#{detail}."

  # No clause for the context's `{:duplicate, existing}`: `add` answers that
  # reason with a success response naming the existing reference, and no other
  # action can produce it, so nothing forwards it here. The catch-alls below
  # cover it if that ever changes.
  def message(reason, %{action_verb: verb}), do: "Failed to #{verb}: #{inspect(reason)}"
  def message(reason, _ctx), do: "Operation failed: #{inspect(reason)}"
end
