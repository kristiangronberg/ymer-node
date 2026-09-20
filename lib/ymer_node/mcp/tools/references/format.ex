defmodule YmerNode.Mcp.Tools.References.Format do
  @moduledoc """
  Response shaping for the `references` tool.

  **This module does not classify.** It takes the classification a caller
  already holds — `%{source: source, recipe: recipe}` — and renders it. That is
  not a style choice: `YmerNode.References.list_classified/1` has to classify
  every candidate to apply a source filter, so a renderer that classified again
  would repeat that work per reference, and two derivations straddling an
  `accept` could disagree inside one response. Taking the answer as an argument
  makes both impossible rather than merely unlikely.

  Source and recipe are still *derived* rather than stored — see
  `YmerNode.References.Sources` — so a read reflects the declarations in force
  at that moment. What changed is only where in the call that derivation
  happens: once, at the action, instead of once per rendered row.

  A blank fragment, a nil recipe and empty tags are compacted away rather than
  sent as noise — the absent-when-empty wire contract.
  """
  alias YmerNode.Mcp.Tools.Helpers
  alias YmerNode.References.Reference

  @doc """
  One reference, rendered against a classification the caller has already made.
  """
  def reference(%Reference{} = reference, %{source: source, recipe: recipe}) do
    %{
      id: reference.id,
      title: reference.title,
      description: reference.description,
      uri: reference.uri,
      fragment: presence(reference.fragment),
      source: source,
      recipe: recipe,
      tags: reference.tags,
      inserted_at: format_datetime(reference.inserted_at),
      updated_at: format_datetime(reference.updated_at)
    }
    |> Helpers.compact()
  end

  @doc """
  One entry from `YmerNode.References.list_classified/1`, which already carries
  its own classification.
  """
  def classified(%{reference: reference, classification: classification}),
    do: reference(reference, classification)

  @doc """
  One find hit — a classified entry plus its score, which is absent in filter
  mode because nothing ranked.
  """
  def find_hit(%{score: nil} = hit), do: classified(hit)

  def find_hit(%{score: score} = hit), do: hit |> classified() |> Map.put(:score, score)

  defp presence(""), do: nil
  defp presence(value), do: value

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
end
