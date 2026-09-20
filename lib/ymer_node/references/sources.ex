defmodule YmerNode.References.Sources do
  @moduledoc """
  Derives a reference's source and fetch recipe from its uri, at read time and
  never from storage.

  Three sources are built in — `web`, `file` and `other` — and every other one
  is **data**: an accepted script row declares the exact http(s) hosts it claims
  and the single action of its own that accepts a uri whole, and the source
  token is the script's own name. Nothing is declared twice, and a result's
  source therefore names the script that can serve it.

  Because the derivation reads the current declarations on every call, accepting
  a script upgrades every reference pointing at its hosts retroactively, and
  un-accepting it downgrades them in the same moment — those references fall
  back to `web` and lose their recipe. That is a property, not a gap: the
  registry stores where a thing lives, and how to reach it is a fact about the
  node's current capabilities rather than about the reference.

  Classification, in order:

  | uri shape | source | recipe |
  |---|---|---|
  | http(s), host claimed by an accepted script | that script's name | `scripts run` on its declared action |
  | http(s), any other host (or no host at all) | `web` | none |
  | `file://`, or no scheme at all (path-like) | `file` | none |
  | any other scheme | `other` | none |

  A uri's port is no part of a claim — `URI.parse/1` yields the host alone — and
  hosts are compared downcased, because DNS is case-insensitive. Where two
  accepted scripts claim one host the first by script name wins, so the answer
  never depends on the order the rows arrived in; refusing that collision is
  acceptance's job, upstream, not this module's (`YmerNode.Scripts`).

  ## One read per operation

  `declarations/0` is a database query, and every function here that needs it
  takes it as an **argument** instead of calling it. That is the seam's whole
  discipline: an operation reads it once, at the action, and threads it down, so
  a find returning fifty references costs one read rather than fifty — or, worse,
  two or three from different layers of the same call.

  `classify/2` is pure over its arguments for the same reason, and nothing below
  the action layer is allowed to reach back here for a fresh read. If you find
  yourself wanting one, the caller has a copy already.
  """
  import Ecto.Query, only: [from: 2]

  alias YmerNode.Repo
  alias YmerNode.Scripts.Script

  # Sorted, because vocabulary/1 hands this straight to a caller-facing message.
  @builtin_sources ~w(file other web)

  @typedoc """
  A reference's derived classification of its uri: the name of the accepted
  script whose declaration claims the uri's host, else `web` (any other
  http(s)), `file` (`file://` or path-like) or `other` (any other scheme).
  Derived at read time, never stored, never typed; a `find` filter and the fetch
  recipe's dispatch key.
  """
  @type source :: String.t()

  @typedoc """
  An accepted script's claim on a source: the exact http(s) hosts it claims and
  the one action that accepts a uri whole. Consulted at read time, first match
  by script name, built-ins as the fallback.
  """
  @type declaration :: %{name: String.t(), hosts: [String.t()], action: String.t()}

  @doc """
  The declarations in force right now — **one query**, over the accepted script
  rows' denormalised declarations.

  This is the seam, and the only function here that touches the database. It
  reads the row rather than the compiled module on purpose: the declarations
  were denormalised at the write for exactly this, so a classification costs one
  query no matter how many scripts are loaded, and a script this boot could not
  compile still declares what it declared.

  A row contributes nothing unless it is **accepted**, names a `url_action`, and
  claims at least one host. The first is the acceptance invariant — code nobody
  accepted classifies nothing. The other two are what makes a declaration
  usable: a claimed host with no action to call would mint a source token whose
  recipe went nowhere.
  """
  def declarations do
    query =
      from script in Script.accepted(),
        order_by: [asc: script.name],
        select: {script.name, script.declarations}

    query
    |> Repo.all()
    |> Enum.flat_map(&declaration/1)
  end

  defp declaration({name, %{"url_action" => action, "hosts" => [_ | _] = hosts}})
       when is_binary(action),
       do: [%{name: name, hosts: hosts, action: action}]

  defp declaration(_row), do: []

  @doc """
  The three source names the node reserves — the classifications every uri falls
  back to when no script claims it.

  Public because acceptance refuses a script whose derived name is one of them
  (`YmerNode.Scripts`): a script called `web` would shadow the fallback and there
  would be no way to ask for either.
  """
  def builtin_sources, do: @builtin_sources

  @doc """
  The source vocabulary for a set of declarations: the three built-ins plus
  every declaring script's name.

  Takes the declarations rather than fetching them, so an action that has
  already read the seam does not read it a second time to build an error
  message. Sorted, because a caller-facing message is where this usually ends
  up.

  Never a module attribute — the vocabulary grows and shrinks with the accepted
  scripts, so a compile-time copy would start lying the first time one was
  accepted.
  """
  def vocabulary(declarations) when is_list(declarations),
    do: Enum.sort(@builtin_sources ++ Enum.map(declarations, & &1.name))

  @doc """
  The vocabulary as it stands right now — `vocabulary/1` over a fresh read.

  For a caller holding no declarations. Anything inside an operation that has
  already read the seam wants `vocabulary/1` instead.
  """
  def vocabulary, do: vocabulary(declarations())

  @doc """
  Classifies a uri against a set of declarations, answering
  `%{source: source, recipe: recipe}`.

  The **fetch recipe** is the next call a reference's uri resolves to at read
  time: for a declared source, `scripts run` on the declaring script's
  URL-accepting action with the uri whole under `url`; none — `nil` — for a
  built-in source. The node never runs it; the caller does.

  Pure over its two arguments, so the declarations travel in rather than being
  fetched here: a list of references classifies against one lookup, and a test
  can hand it exactly the rows it means.

  ## Examples

      iex> YmerNode.References.Sources.classify("https://elixir-lang.org/docs", [])
      %{recipe: nil, source: "web"}

      iex> YmerNode.References.Sources.classify("/Users/k/notes.md", [])
      %{recipe: nil, source: "file"}

      iex> YmerNode.References.Sources.classify("mailto:someone@example.fi", [])
      %{recipe: nil, source: "other"}

  """
  def classify(uri, declarations) when is_binary(uri) and is_list(declarations) do
    trimmed = String.trim(uri)

    case URI.parse(trimmed) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] ->
        http_source(host, trimmed, declarations)

      %URI{scheme: "file"} ->
        built_in("file")

      %URI{scheme: nil} ->
        built_in("file")

      %URI{} ->
        built_in("other")
    end
  end

  # The non-empty-host guard is load-bearing: a host-less http uri
  # ("https:notes") parses with host nil, and a declaration carrying a blank
  # host would then match it and attach a recipe that resolves to nothing. A
  # guaranteed non-empty binary can never equal the nil such a uri parses to.
  defp http_source(host, uri, declarations) when is_binary(host) and host != "" do
    downcased = String.downcase(host)

    case declarations |> Enum.sort_by(& &1.name) |> Enum.find(&claims?(&1, downcased)) do
      nil -> built_in("web")
      declaration -> %{source: declaration.name, recipe: recipe(declaration, uri)}
    end
  end

  defp http_source(_no_host, _uri, _declarations), do: built_in("web")

  defp claims?(declaration, downcased_host),
    do: Enum.any?(declaration.hosts, &(String.downcase(&1) == downcased_host))

  defp built_in(source), do: %{source: source, recipe: nil}

  # One fixed shape, no template and no placeholder grammar. The contract a
  # declaring action signs is that it accepts the uri whole under `url`.
  defp recipe(declaration, uri) do
    %{
      tool: "scripts",
      action: "run",
      params: %{
        "script" => declaration.name,
        "action" => declaration.action,
        "args" => %{"url" => uri}
      }
    }
  end
end
