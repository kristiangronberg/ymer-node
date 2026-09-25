defmodule YmerNode.Mcp.Tools.ScriptAuthor.Actions do
  @moduledoc """
  Action implementations for the `script_author` tool — the boundary over
  `YmerNode.Scripts`'s write verbs.

  Same shape as `YmerNode.Mcp.Tools.Scripts.Actions`, and for the same reason:
  every extracted scalar is guarded on its head, and each guarded head is
  followed by a wrong-typed twin that answers a message rather than letting the
  context's own guard raise. Two strings, nothing else — there is no range and
  no vocabulary here, so there is no `Validate` layer.

  `create`'s response carries the stored script the way `update` and `accept`
  do, rather than only its name: a caller that has just written a script wants
  to see what the node made of it — the derived name most of all, since it never
  supplied one.
  """
  alias YmerNode.Mcp.Tools.Helpers
  alias YmerNode.Mcp.Tools.ScriptFormat
  alias YmerNode.Scripts

  def run(:check, %{"code" => code}) when is_binary(code), do: check(code)
  def run(:create, %{"code" => code}) when is_binary(code), do: create(code)

  def run(:update, %{"script" => script, "code" => code})
      when is_binary(script) and is_binary(code),
      do: update(script, code)

  def run(:accept, %{"script" => script}) when is_binary(script), do: accept(script)
  def run(:remove, %{"script" => script}) when is_binary(script), do: remove(script)

  # The wrong-typed twins, after every guarded head.
  def run(:check, %{"code" => code}),
    do: Helpers.wrong_type("code", "a string", code, "check code")

  def run(:create, %{"code" => code}),
    do: Helpers.wrong_type("code", "a string", code, "create a script")

  def run(:update, %{"script" => script}) when not is_binary(script),
    do: Helpers.wrong_type("script", "a string", script, "update a script")

  def run(:update, %{"code" => code}),
    do: Helpers.wrong_type("code", "a string", code, "update a script")

  def run(:accept, %{"script" => script}),
    do: Helpers.wrong_type("script", "a string", script, "accept a script")

  def run(:remove, %{"script" => script}),
    do: Helpers.wrong_type("script", "a string", script, "remove a script")

  # An empty hint context: the hint steers at `create` and needs nothing from
  # here — the caller holds the code, and a context carrying it would put the
  # whole script into the response a second time.
  defp check(code) do
    case Scripts.check(code) do
      {:ok, compiled} -> {:ok, ScriptFormat.checked(compiled), %{}}
      {:error, reason} -> {:error, {reason, %{action_verb: "check code"}}}
    end
  end

  defp create(code), do: written(Scripts.create(code), "create a script")

  defp update(script, code), do: written(Scripts.update(script, code), "update a script")

  defp accept(script), do: written(Scripts.accept(script), "accept a script")

  defp remove(script) do
    case Scripts.remove(script) do
      {:ok, removed} -> {:ok, %{removed: removed.script.name, schedules: removed.schedules}, %{}}
      {:error, reason} -> {:error, {reason, %{action_verb: "remove a script"}}}
    end
  end

  # Every write answers the stored script the same way, read back through the
  # same renderer `scripts describe` uses, so a caller sees one shape whichever
  # door it came in by. A remove landing between the write and this read is a
  # rendered refusal like any other, never a match failing at the boundary.
  defp written({:ok, script}, verb) do
    case Scripts.describe(script.name) do
      {:ok, entry} -> {:ok, ScriptFormat.detail(entry), %{script: script.name}}
      {:error, reason} -> {:error, {reason, %{action_verb: verb}}}
    end
  end

  defp written({:error, reason}, verb), do: {:error, {reason, %{action_verb: verb}}}
end
