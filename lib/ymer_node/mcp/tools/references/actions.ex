defmodule YmerNode.Mcp.Tools.References.Actions do
  @moduledoc """
  Action implementations for the `references` tool — the boundary over the
  `YmerNode.References` context.

  This is a trust boundary. Its shape check is on the heads — every `run/2`
  clause guards `is_map(data)`, because it binds the params map whole, and each
  private head pattern-matches the keys the schema declares required. Its
  *value* checks sit one layer down: `YmerNode.Mcp.Tools.References.Validate`
  type-checks every scalar a find or an id-bearing action extracts, and the
  `YmerNode.References.Reference` changeset does the same for every field add
  and update write, so no value reaches anything type-assuming before one of
  those two has judged it. The notebook tool guards its extracted scalars on the
  heads as well, because its values flow straight into SQLite and into filename
  construction with nothing in between; that is not this tool's shape.

  **One read of the seam per action, threaded down.**
  `YmerNode.References.Sources.declarations/0` is a database query, and every
  action that needs it reads it once at the top and passes it on — to
  `YmerNode.Mcp.Tools.References.Validate` for the source vocabulary, to
  `YmerNode.References` for the filter, and into the error context so an
  invalid-source message names the same vocabulary the call was judged against.
  Nothing below this layer reaches back for a fresh read, and
  `YmerNode.Mcp.Tools.References.Format` cannot classify at all — it takes the
  answer. A find returning fifty references costs one read and fifty
  classifications, which is the floor.

  add's duplicate branch is deliberately a SUCCESS response. An LLM reads an
  error as "retry differently", which would fork the registry through a slightly
  mutated uri; pointing at the reference that already exists, with an
  update-or-tag steer, converges instead.
  """

  alias YmerNode.Mcp.Tools.Helpers
  alias YmerNode.Mcp.Tools.References.{Format, Validate}
  alias YmerNode.References
  alias YmerNode.References.Sources

  def run(:find, data) when is_map(data), do: find(data)
  def run(:add, data) when is_map(data), do: add(data)
  def run(:get, data) when is_map(data), do: get(data)
  def run(:update, data) when is_map(data), do: update(data)
  def run(:remove, data) when is_map(data), do: remove(data)
  def run(:list, data) when is_map(data), do: list(data)

  defp find(data) do
    # The one read this action makes. It goes on the context too, so an
    # invalid-source message names the vocabulary this call was judged against
    # rather than one from a second read that could disagree with it.
    declarations = Sources.declarations()
    ctx = %{action_verb: "find references", data: data, declarations: declarations}

    with {:ok, query} <- Validate.optional_query(data["query"]),
         {:ok, tags} <- Validate.tags(data["tags"]),
         {:ok, source} <- Validate.source(data["source"], declarations),
         :ok <- Validate.some_criterion(query, tags, source),
         {:ok, limit} <- Validate.limit(data["limit"]) do
      %{mode: mode, results: results} =
        References.find_references(
          query: query,
          tags: tags,
          source: source,
          limit: limit,
          declarations: declarations
        )

      {:ok,
       %{
         mode: Atom.to_string(mode),
         count: length(results),
         results: Enum.map(results, &Format.find_hit/1)
       }, %{}}
    else
      {:error, reason} -> {:error, {reason, ctx}}
    end
  end

  # The seam is read on the two branches that render, and only there: a refused
  # insert classifies nothing, so it never pays for the query.
  defp add(%{"title" => _title, "uri" => _uri} = data) do
    ctx = %{action_verb: "add reference", data: data}

    case References.create_reference(reference_attrs(data)) do
      {:ok, reference} ->
        {:ok,
         %{
           message: "Reference ##{reference.id} added",
           reference: render(reference, Sources.declarations())
         }, %{id: reference.id}}

      {:error, {:duplicate, existing}} ->
        {:ok,
         %{
           message:
             "A reference for this uri and fragment already exists as ##{existing.id} — " <>
               "update or tag it instead of re-adding.",
           reference: render(existing, Sources.declarations())
         }, %{id: existing.id, duplicate: true}}

      {:error, reason} ->
        {:error, {reason, ctx}}
    end
  end

  defp get(%{"id" => _id} = data) do
    ctx = %{action_verb: "get reference", data: data}

    with {:ok, id} <- Validate.id(data["id"]),
         {:ok, reference} <- References.get_reference(id) do
      {:ok, %{reference: render(reference, Sources.declarations())}, %{}}
    else
      {:error, reason} -> {:error, {reason, ctx}}
    end
  end

  defp update(%{"id" => _id} = data) do
    ctx = %{action_verb: "update reference", data: data}

    with {:ok, id} <- Validate.id(data["id"]),
         {:ok, reference} <- References.get_reference(id),
         {:ok, updated} <- References.update_reference(reference, reference_attrs(data)) do
      {:ok,
       %{
         message: "Reference ##{updated.id} updated",
         reference: render(updated, Sources.declarations())
       }, %{id: updated.id}}
    else
      {:error, reason} -> {:error, {reason, ctx}}
    end
  end

  defp remove(%{"id" => _id} = data) do
    ctx = %{action_verb: "remove reference", data: data}

    with {:ok, id} <- Validate.id(data["id"]),
         {:ok, reference} <- References.get_reference(id),
         {:ok, _deleted} <- References.delete_reference(reference) do
      {:ok, %{message: "Reference ##{id} removed"}, %{}}
    else
      {:error, reason} -> {:error, {reason, ctx}}
    end
  end

  defp list(_data) do
    entries = References.list_classified()

    {:ok,
     %{
       count: length(entries),
       references: Enum.map(entries, &Format.classified/1)
     }, %{}}
  end

  # The single-reference actions classify the one row they hold, against the one
  # read they made. `Format` takes the classification rather than making it.
  defp render(reference, declarations) do
    Format.reference(reference, Sources.classify(reference.uri, declarations))
  end

  # add and update take the same five fields and forward them the same way — by
  # key PRESENCE, so an explicit null reaches the changeset and clearing a field
  # keeps working.
  defp reference_attrs(data) do
    %{}
    |> Helpers.maybe_put_if_present(data, "title", :title)
    |> Helpers.maybe_put_if_present(data, "description", :description)
    |> Helpers.maybe_put_if_present(data, "uri", :uri)
    |> Helpers.maybe_put_if_present(data, "fragment", :fragment)
    |> Helpers.maybe_put_if_present(data, "tags", :tags)
  end
end
