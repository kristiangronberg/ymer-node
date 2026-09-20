defmodule YmerNode.Mcp.Tools.References.Validate do
  @moduledoc """
  Value validation for the `references` tool's params.

  The dispatch layer checks that a required param is PRESENT but is blind to
  what it holds, so these functions are the boundary's value checks: every
  extracted scalar is type-checked before use, and each failure is a distinct
  atom so `YmerNode.Mcp.Tools.References.Errors` can render specific recovery
  guidance rather than one shrug for everything.
  """

  alias YmerNode.References
  alias YmerNode.References.Sources

  @default_limit 50
  @max_limit 100

  def id(id) do
    case References.parse_id(id) do
      {:ok, n} -> {:ok, n}
      :error -> {:error, :invalid_id}
    end
  end

  def optional_query(nil), do: {:ok, nil}

  def optional_query(query) when is_binary(query) do
    case String.trim(query) do
      "" -> {:error, :empty_query}
      trimmed -> {:ok, trimmed}
    end
  end

  def optional_query(_query), do: {:error, :empty_query}

  def tags(nil), do: {:ok, nil}

  def tags(tags) when is_list(tags) do
    if Enum.all?(tags, &is_binary/1), do: {:ok, tags}, else: {:error, :invalid_tags}
  end

  def tags(_tags), do: {:error, :invalid_tags}

  @doc """
  Checks a source token against the vocabulary the caller's declarations imply.

  The declarations travel in rather than being fetched here: the action has read
  the seam already, and reading it again to validate one string would be a
  second query per call — for a token that is checked against the same answer
  the rest of the call is using.

  The token stays a string all the way through. It cannot become an atom: a
  declared source is an accepted script's name, which is user data, so
  `String.to_existing_atom/1` would fail on every newly accepted script and
  `String.to_atom/1` would let a caller grow the atom table at will.
  """
  def source(nil, _declarations), do: {:ok, nil}

  def source(source, declarations) when is_binary(source) and is_list(declarations) do
    if source in Sources.vocabulary(declarations),
      do: {:ok, source},
      else: {:error, :invalid_source}
  end

  def source(_source, _declarations), do: {:error, :invalid_source}

  @doc "find needs at least one criterion — an empty find is not a table dump; that is `list`."
  def some_criterion(nil, tags, nil) when tags in [nil, []], do: {:error, :empty_find}
  def some_criterion(_query, _tags, _source), do: :ok

  @doc """
  Normalizes a limit.

  The declared integer type is advisory — the dispatch gate checks presence, not
  value type — so a positive numeric string is accepted, and an over-max value
  CLAMPS to the maximum rather than bouncing. A caller that asks for 500 wants
  as many as it can have, and refusing the call teaches it nothing it can act on.
  """
  def limit(nil), do: {:ok, @default_limit}
  def limit(n) when is_integer(n) and n > 0, do: {:ok, min(n, @max_limit)}

  def limit(s) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {n, ""} when n > 0 -> {:ok, min(n, @max_limit)}
      _not_a_positive_integer -> {:error, :invalid_limit}
    end
  end

  def limit(_limit), do: {:error, :invalid_limit}
end
