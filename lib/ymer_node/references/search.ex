defmodule YmerNode.References.Search do
  @moduledoc """
  The find surface — two composable layers on one call.

  1. **Filters** — tag-AND and derived source, fetched through
     `YmerNode.References.list_classified/1` rather than from the repo directly,
     so those rules stay implemented once. The resulting cycle between the two
     modules is runtime-only: a `defdelegate` out and a plain call back.
  2. **Keyword floor** — a score of distinct query terms matched against
     `YmerNode.References.Reference.search_text/1`, which is every text field, so
     a term carried only by a uri still matches.

  `mode` names what ran: `:keyword` when a query was given, `:filter` when none
  was — filters only, newest first. There are two modes and not three. Ranking
  by embedding is a knowing omission rather than an unimplemented branch: the
  node ships no embedding provider for the registry, and a mode that silently
  fell back would tell a caller its query had been ranked one way when it had
  been ranked the other.

  Ties break newest-updated first, then by id descending, so an equal-scoring
  pair has a stable order rather than the repo's.
  """

  alias YmerNode.References
  alias YmerNode.References.Reference

  # Terms shorter than this match too much to be evidence of anything, and a
  # query long enough to need more than @max_terms is being used as prose
  # rather than as a search.
  @min_term_length 2
  @max_terms 8

  @doc """
  Runs a find. Options: `:query` (a string, or nil for filter mode), `:tags`
  (tag-AND list), `:source` (a source token), `:limit` (a positive integer, or
  nil for all).

  Answers `%{mode: :keyword | :filter, results: results}`, where each result is
  `%{reference: %YmerNode.References.Reference{}, classification: %{source:
  source, recipe: recipe}, score: number | nil}` — the score is nil in filter
  mode, because nothing ranked.

  The classification rides along rather than being derived by whoever renders
  the hit: `YmerNode.References.list_classified/1` had to compute it to apply
  the source filter, and passing `:declarations` through means one operation
  reads the seam once. `:declarations` is optional here for the same reason it
  is there — a caller with none in hand gets one read rather than a crash.
  """
  def run(opts \\ []) when is_list(opts) do
    entries =
      References.list_classified(
        tags: opts[:tags],
        source: opts[:source],
        order: :recent,
        declarations: opts[:declarations]
      )

    case opts[:query] do
      nil ->
        %{mode: :filter, results: filter_results(entries, opts[:limit])}

      query when is_binary(query) ->
        %{mode: :keyword, results: keyword_results(query, entries, opts[:limit])}
    end
  end

  @doc """
  Splits a query into the distinct terms a keyword score counts.

  Downcased, split on anything that is not a letter, a number or a hyphen — so
  an identifier like `ABC-1234` survives as one term — then deduplicated and
  capped.

  ## Examples

      iex> YmerNode.References.Search.tokenize("Release notes, ABC-1234")
      ["release", "notes", "abc-1234"]

      iex> YmerNode.References.Search.tokenize("a I x")
      []

      iex> YmerNode.References.Search.tokenize("dup DUP dup")
      ["dup"]

  """
  def tokenize(query) when is_binary(query) do
    query
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}-]+/u, trim: true)
    |> Enum.filter(&(String.length(&1) >= @min_term_length))
    |> Enum.uniq()
    |> Enum.take(@max_terms)
  end

  defp filter_results(entries, limit) do
    entries
    |> Enum.map(&Map.put(&1, :score, nil))
    |> maybe_take(limit)
  end

  defp keyword_results(query, entries, limit) do
    case tokenize(query) do
      [] ->
        []

      terms ->
        entries
        |> Enum.map(&Map.put(&1, :score, score(&1.reference, terms)))
        |> Enum.reject(&(&1.score == 0))
        |> sort_ranked()
        |> maybe_take(limit)
    end
  end

  defp score(reference, terms) do
    text = reference |> Reference.search_text() |> String.downcase()
    Enum.count(terms, &String.contains?(text, &1))
  end

  defp sort_ranked(results) do
    Enum.sort_by(results, fn %{reference: reference, score: score} ->
      {-score, -DateTime.to_unix(reference.updated_at), -reference.id}
    end)
  end

  defp maybe_take(results, nil), do: results

  defp maybe_take(results, limit) when is_integer(limit) and limit > 0,
    do: Enum.take(results, limit)
end
