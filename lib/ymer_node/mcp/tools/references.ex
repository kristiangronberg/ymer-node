defmodule YmerNode.Mcp.Tools.References do
  @moduledoc """
  Wymcp tool `references` — the registry of pointers at where knowledge lives.

  A thin boundary over `YmerNode.References`: bare-verb actions over a single
  entity, with this module wiring only the framework's callbacks. What the
  registry is, and why a reference is a pointer and never content, live in the
  context's own moduledoc.

  Destructive, because `remove` hard-deletes a stored reference. Closed-world
  all the same: the tool touches nothing but this node's own database — it is
  the RESULTS that point outward, and following one is the caller's own call to
  make.
  """
  use Wymcp.Tool

  alias YmerNode.Mcp.Tools.References.{Actions, Errors, Schemas}
  alias YmerNode.Mcp.Tools.References.Hints, as: ReferencesHints

  @impl true
  def name, do: "references"

  @impl true
  def title, do: "References"

  @impl true
  def annotations, do: %{"destructiveHint" => true, "openWorldHint" => false}

  @impl true
  def description,
    do:
      "Pointers to where knowledge lives — websites, files, app links, and the " <>
        "systems your scripts declare. find routes you by tags, source, and free " <>
        "text; every result carries its source and, where one is derivable, a " <>
        "fetch recipe (tool + action + params) — call that yourself for the live " <>
        "content, this tool never fetches. Store pointers and routing notes, " <>
        "never copies of content. Until registry sync lands, what you add here " <>
        "lives only on this machine."

  @impl true
  def actions, do: Schemas.all()

  @impl true
  def run_action(action, data, _ctx), do: Actions.run(action, data)

  @impl true
  def hints(action, hint_context), do: ReferencesHints.for(action, hint_context)

  @impl true
  def handle_error({reason, ctx}) when is_map(ctx), do: Errors.format(reason, ctx)
  def handle_error(reason), do: Errors.format(reason)
end
