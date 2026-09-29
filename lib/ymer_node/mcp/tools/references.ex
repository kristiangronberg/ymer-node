defmodule YmerNode.Mcp.Tools.References do
  @moduledoc """
  Wymcp tool `references` — the registry of pointers at where knowledge lives,
  and the cache of what their targets say.

  A thin boundary over `YmerNode.References`: bare-verb actions over a single
  entity, with this module wiring the framework's callbacks and one clause of
  its own (below). What the registry and the cache are, and the rule between
  them, live in the context's own moduledoc (§ The membrane).

  Open-world, because `read` on a miss, `refresh` and `watch` run the
  reference's script, and a script reaches the network with the node's own
  permissions. Destructive on account of `remove` alone: it hard-deletes a
  reference, and until registry sync lands the node database holds the only
  copy of it. Dropping a cache entry or a watch loses nothing a refetch does
  not restore.

  ## The image clause

  wymcp answers every action as one JSON text block, so an image `read`
  serves would reach a client as base64 inside text. The last `run/2` clause
  here takes the `read` action alone: it runs the framework's own dispatch —
  every argument gate, the required and unknown-param checks and the defaults
  — and, when the answer carries an image, answers it as an image block beside
  the rest of the answer in JSON. Every other answer passes through as it came.
  """
  use Wymcp.Tool

  alias Wymcp.Context
  alias Wymcp.Tool

  alias YmerNode.Mcp.Tools.References.{Actions, Errors, Schemas}
  alias YmerNode.Mcp.Tools.References.Hints, as: ReferencesHints

  @impl true
  def name, do: "references"

  @impl true
  def title, do: "References"

  @impl true
  def annotations, do: %{"destructiveHint" => true, "openWorldHint" => true}

  @impl true
  def description,
    do:
      "Pointers to where knowledge lives — websites, files, app links, and the " <>
        "systems your scripts declare — and a cache of what they say. find routes " <>
        "you by tags, source, and free text; every result carries its source and, " <>
        "where one is derivable, a fetch recipe (tool + action + params). read " <>
        "serves a reference's content from the cache — text by line window, " <>
        "images as images — running its recipe once when nothing is cached; " <>
        "refresh asks again now; watch keeps it current for a few hours. Every " <>
        "answer says how old the content is. Store pointers and routing notes " <>
        "here, never content. Until registry sync lands, what you add here lives " <>
        "only on this machine."

  @impl true
  def actions, do: Schemas.all()

  @impl true
  def run_action(action, data, _ctx), do: Actions.run(action, data)

  @impl true
  def hints(action, hint_context), do: ReferencesHints.for(action, hint_context)

  @impl true
  def handle_error({reason, ctx}) when is_map(ctx), do: Errors.format(reason, ctx)
  def handle_error(reason), do: Errors.format(reason)

  defp image_content(json, answer) do
    case JSON.decode!(json) do
      %{"image" => %{"data" => data, "mime_type" => media_type}} = read ->
        {:ok, Context.image(data, media_type) ++ Context.json(Map.delete(read, "image"))}

      _text_or_described ->
        answer
    end
  end

  # Remediation(removable: wymcp lets run_action/3 answer non-text content):
  # the image clause (§ The image clause). It sits last, and every callback
  # above carries `@impl`: the shape that compiles without a warning beside the
  # run/2 wymcp injects.
  # plan: 2026-09-29-references-fetch-and-cache
  @impl true
  def run(%Context{} = ctx, %{"action" => "read"} = arguments) do
    case Tool.dispatch(__MODULE__, ctx, arguments) do
      {:ok, [%{"type" => "text", "text" => json}]} = answer -> image_content(json, answer)
      other -> other
    end
  end
end
