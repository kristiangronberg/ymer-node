defmodule YmerNode.Mcp.Tools.Scripts.Actions do
  @moduledoc """
  Action implementations for the `scripts` tool — the boundary over
  `YmerNode.Scripts`.

  This is a trust boundary, and it takes the shape
  `YmerNode.Mcp.Tools.Notebook.Actions` takes rather than the one
  `YmerNode.Mcp.Tools.References.Actions` takes: every extracted scalar is
  guarded on the head, and each guarded head is followed by a **wrong-typed
  twin** that answers a message. There is no `Validate` layer because there is
  nothing here to validate beyond type — no ranges, no vocabularies, no id that
  may arrive as either an integer or its string form. The values are four
  strings and a map, and the action's own JSON Schema, which
  `YmerNode.Scripts.Runner` applies, is what judges their *content*; `info`'s
  one vocabulary, the promised package names, is judged by
  `YmerNode.Scripts.PackageDocs`, which refuses an unknown name naming every
  accepted one.

  The twins are what make that a boundary rather than a crash. `YmerNode.Scripts`
  and `YmerNode.Scripts.Runner` both guard `is_binary(action)`, so a wire call
  carrying `action: 123` would raise `FunctionClauseError` and answer a caller
  nothing it could act on. Grouped after the guarded heads, never before: a twin
  that ran first would swallow every good call.

  `describe`'s hint context carries a runnable action only when the script is
  both accepted and compiled, and `code: true` whenever the code was asked for
  — see `YmerNode.Mcp.Tools.Scripts.Hints` for why the decision is made here
  and not there.
  """
  alias YmerNode.Mcp.Tools.Helpers
  alias YmerNode.Mcp.Tools.ScriptFormat
  alias YmerNode.Scripts
  alias YmerNode.Scripts.Guide
  alias YmerNode.Scripts.PackageDocs

  def run(:list, data) when is_map(data), do: list()
  def run(:guide, data) when is_map(data), do: guide()
  def run(:info, %{"name" => name}) when is_binary(name), do: info(name)

  def run(:describe, %{"script" => script} = data) when is_binary(script),
    do: describe(script, Map.get(data, "code", false))

  def run(:run, %{"script" => script, "action" => action} = data)
      when is_binary(script) and is_binary(action),
      do: run_action(script, action, Map.get(data, "args", %{}))

  # The wrong-typed twins, after every guarded head.
  def run(:info, %{"name" => name}),
    do: Helpers.wrong_type("name", "a string", name, "render a package's docs")

  def run(:describe, %{"script" => script}),
    do: Helpers.wrong_type("script", "a string", script, "describe a script")

  def run(:run, %{"script" => script}) when not is_binary(script),
    do: Helpers.wrong_type("script", "a string", script, "run a script")

  def run(:run, %{"action" => action}),
    do: Helpers.wrong_type("action", "a string", action, "run a script")

  defp list do
    scripts = Enum.map(Scripts.list(), &ScriptFormat.summary/1)
    {:ok, %{count: length(scripts), scripts: scripts}, %{}}
  end

  defp guide do
    case Guide.render() do
      {:ok, text} -> {:ok, %{guide: text}, %{}}
      {:error, reason} -> {:error, {reason, %{action_verb: "render the guide"}}}
    end
  end

  defp info(name) do
    case PackageDocs.render(name) do
      {:ok, text} -> {:ok, %{name: name, docs: text}, %{}}
      {:error, reason} -> {:error, {reason, %{action_verb: "render a package's docs"}}}
    end
  end

  defp describe(script, code?) when is_boolean(code?) do
    case Scripts.describe(script, code: code?) do
      {:ok, entry} ->
        detail = ScriptFormat.detail(entry)
        {:ok, detail, hint_context(detail)}

      {:error, reason} ->
        {:error, {reason, %{action_verb: "describe a script"}}}
    end
  end

  defp describe(_script, code?),
    do: Helpers.wrong_type("code", "true or false", code?, "describe a script")

  defp run_action(script, action, args) when is_map(args) do
    case Scripts.run(script, action, args) do
      {:ok, result} -> {:ok, %{script: script, action: action, result: result}, %{}}
      {:error, reason} -> {:error, {reason, %{action_verb: "run a script"}}}
    end
  end

  defp run_action(_script, _action, args),
    do: Helpers.wrong_type("args", "an object", args, "run a script")

  # A run hint only where a run would actually be served. `Map.keys/1` over the
  # RENDERED actions rather than the entry's, so the name in the example is the
  # string the wire uses; the alphabetically first, so two calls agree. A
  # sharing hint whenever the code was asked for, whatever the script's state:
  # sharing needs the bytes and nothing else.
  defp hint_context(detail), do: Map.merge(runnable(detail), shareable(detail))

  defp runnable(%{accepted: true, loaded: true, name: name, actions: actions})
       when map_size(actions) > 0 do
    %{script: name, action: actions |> Map.keys() |> Enum.min()}
  end

  defp runnable(_detail), do: %{}

  defp shareable(%{name: name, code: code}) when is_binary(code), do: %{script: name, code: true}
  defp shareable(_detail), do: %{}
end
