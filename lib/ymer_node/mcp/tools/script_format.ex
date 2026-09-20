defmodule YmerNode.Mcp.Tools.ScriptFormat do
  @moduledoc """
  Response shaping for both script tools — `YmerNode.Mcp.Tools.Scripts` and
  `YmerNode.Mcp.Tools.ScriptAuthor`.

  A sibling of `YmerNode.Mcp.Tools.Helpers` rather than a layer under either
  tool, because it is the one thing the two genuinely share and no tool in this
  node reaches into another tool's namespace. It is also not a second `Helpers`:
  that module's charter is "needed by more than one tool layer and with no home
  of its own", and a script renderer has a subject, which is why it is named for
  it.

  What is shared and what is not: **rendering** a script is one job with two
  callers — `list` and all four write verbs answer the same summary, `describe`
  and `check` answer the same action schemas — while **error messages** are not,
  and stay in each tool's own `Errors`. The two tools' refusal sets barely
  overlap: everything `scripts` can answer comes from the runner, everything
  `script_author` can answer comes from the compiler and from acceptance, and a
  shared module would be a union that each tool half-uses.

  Two conventions, both inherited from `YmerNode.Mcp.Tools.References.Format`:
  field names are atoms and dynamic keys — an action's name — are strings, which
  is what keeps a schema map from minting atoms; and nils and empty lists are
  compacted away rather than sent as noise.
  """
  alias YmerNode.Mcp.Tools.Helpers

  @doc """
  One script as `list` and the write verbs answer it: what it is, whether it can
  run, and why not where it cannot.

  `accepted?` becomes `accepted` and `loaded?` becomes `loaded`: a trailing
  question mark is Elixir's convention for a predicate and means nothing on the
  wire.
  """
  def summary(entry) when is_map(entry) do
    %{
      name: entry.name,
      description: entry.description,
      origin: entry.origin,
      accepted: entry.accepted?,
      loaded: entry.loaded?,
      actions: Enum.map(entry.actions, &Atom.to_string/1),
      error: error(entry.error)
    }
    |> Helpers.compact()
  end

  @doc """
  One script in full, as `describe` answers it — the summary plus the contract,
  the acceptance time, the declarations, each action's whole schema, and the code
  where it was asked for.
  """
  def detail(entry) when is_map(entry) do
    entry
    |> Map.put(:actions, Map.keys(entry.actions))
    |> summary()
    |> Map.merge(%{
      contract: entry.contract,
      accepted_at: datetime(entry.accepted_at),
      declarations: entry.declarations,
      actions: actions(entry.actions),
      warnings: entry.warnings,
      code: entry.code
    })
    |> Helpers.compact()
  end

  @doc """
  What `check` answers: the same view of a candidate that never became a row, so
  there is no origin, no acceptance and no boot to report — plus `existing`,
  which says whether this node already holds a script of that name.

  `existing` is never left out, for the reason the write mark is not: `true`
  means `create` would be refused and `update` is the call to make, and it is
  the answer a caller came here for rather than an optional extra. A key that
  disappears when it is false is a key a reader stops looking for. The
  compaction keeps it because `YmerNode.Mcp.Tools.Helpers.compact/1` drops
  nils and empty lists and nothing else — a boolean survives — and the test on
  the false case is what holds that, so a tightened `compact/1` is caught there
  rather than papered over here.
  """
  def checked(compiled) when is_map(compiled) do
    %{
      name: compiled.name,
      description: compiled.description,
      contract: compiled.contract,
      declarations: compiled.declarations,
      actions: actions(compiled.actions),
      warnings: compiled.warnings,
      existing: compiled.existing
    }
    |> Helpers.compact()
  end

  @doc """
  An actions map as the wire carries it: keyed by the action's name as a string,
  each schema carrying its write mark and, where the script names one, its
  timeout.

  The write mark is never omitted, even when false. It is the flag a worker is
  told to read before it acts, and a key that disappears when it is false is a
  key a reader stops looking for — the compaction keeps a boolean, and the
  wire test on a `write: false` action pins that it does.
  """
  def actions(actions) when is_map(actions) do
    Map.new(actions, fn {name, schema} -> {Atom.to_string(name), action(schema)} end)
  end

  defp action(schema) do
    %{
      description: schema.description,
      properties: schema.properties,
      required: Map.get(schema, :required, []),
      write: schema.write,
      timeout: Map.get(schema, :timeout)
    }
    |> Helpers.compact()
  end

  defp error(nil), do: nil
  defp error({reason, detail}), do: "#{reason}: #{detail}"

  defp datetime(nil), do: nil
  defp datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
end
