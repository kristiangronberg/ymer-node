defmodule YmerNode.Mcp.Tools.Helpers do
  @moduledoc """
  The four helpers a tool's action and format layers share, and nothing else.

  Deliberately narrow. This is the node's first module of its kind, and a
  grab-bag named `Helpers` grows without anyone deciding it should: each
  function here earns its place by being needed by more than one tool layer and
  by having no home of its own. `Wymcp` offers no public equivalent of any of
  them.
  """

  @doc """
  Copies `params[param_key]` into `map` under `attr_key`, but only when
  `param_key` is PRESENT in `params`.

  Presence, not truthiness, and that is the whole point: an explicit JSON null
  is a value the caller meant to send — clearing a description by passing null
  has to keep working — so a null travels through to the changeset, which is
  where its meaning is decided. Filtering nils here would silently turn "clear
  this field" into "leave it alone".
  """
  def maybe_put_if_present(map, params, param_key, attr_key) when is_map(params) do
    if Map.has_key?(params, param_key) do
      Map.put(map, attr_key, params[param_key])
    else
      map
    end
  end

  @doc """
  Drops nil values and empty lists from a map — the absent-when-empty wire
  contract, so a response carries no keys whose only content is "nothing here".

  ## Examples

      iex> YmerNode.Mcp.Tools.Helpers.compact(%{a: 1, b: nil, c: [], d: [1]})
      %{a: 1, d: [1]}

  A boolean is content, so a flag that is `false` stays — the write mark and
  `existing` depend on that:

      iex> YmerNode.Mcp.Tools.Helpers.compact(%{write: false, existing: false})
      %{existing: false, write: false}

  """
  def compact(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == [] end)
    |> Map.new()
  end

  @doc """
  The wrong-typed twin's answer: what a boundary action gives back when a
  present key holds a value of the wrong type — the key, what was expected,
  what arrived, and the verb the message is rendered under.

  One shape across every tool, so each tool's `Errors` reads one map and a
  twin is one line at its head rather than a tuple spelled by hand.

  ## Examples

      iex> YmerNode.Mcp.Tools.Helpers.wrong_type("sql", "a string", 7, "run query")
      {:error, {{:wrong_type, %{key: "sql", expected: "a string", got: 7}}, %{action_verb: "run query"}}}

  """
  def wrong_type(key, expected, got, verb)
      when is_binary(key) and is_binary(expected) and is_binary(verb) do
    {:error, {{:wrong_type, %{key: key, expected: expected, got: got}}, %{action_verb: verb}}}
  end

  @doc """
  Renders a changeset's errors as one string a caller can act on, with each
  message's interpolations already applied.

  Total over whatever the changeset holds: a placeholder the opts do not name
  stays as written — `%{count}` rather than a bare `count`, so a lost opt is
  visible — and a named value with no `String.Chars` implementation renders
  through `inspect/1` rather than raising.
  """
  def format_changeset_errors(%Ecto.Changeset{} = changeset) do
    errors =
      changeset
      |> Ecto.Changeset.traverse_errors(&interpolate/1)
      |> Enum.map_join("\n", fn {field, field_messages} ->
        "- #{field}: #{Enum.join(field_messages, ", ")}"
      end)

    "Validation failed:\n#{errors}\n\nPlease correct the input and try again."
  end

  # Substitutes only the placeholders the message names, matched against the
  # opts by name without touching the atom table. The earlier fold pushed every
  # opt through `to_string/1`: a cast error carries its type in the opts —
  # `tags: {"is invalid", [type: {:array, :string}, validation: :cast]}` — and
  # that tuple has no `String.Chars` implementation, so the fold raised
  # `Protocol.UndefinedError` on a message ("is invalid") holding no
  # interpolation at all. Reachable from the wire: the dispatch layer checks a
  # param's presence and never its type, so `add`/`update` with a non-array
  # `tags` crashed the call instead of answering "tags: is invalid". A
  # `String.to_existing_atom/1` on the placeholder would trade that raise for
  # an `ArgumentError` on any key the VM holds no atom for, which is why the
  # match is by name and an unmatched placeholder is left as written.
  defp interpolate({message, opts}) do
    Regex.replace(~r"%{(\w+)}", message, fn whole, key ->
      Enum.find_value(opts, whole, fn {name, value} ->
        Atom.to_string(name) == key and render(value)
      end)
    end)
  end

  defp render(value) do
    if String.Chars.impl_for(value), do: to_string(value), else: inspect(value)
  end
end
