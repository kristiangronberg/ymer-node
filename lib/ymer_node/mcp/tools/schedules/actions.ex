defmodule YmerNode.Mcp.Tools.Schedules.Actions do
  @moduledoc """
  Action implementations for the `schedules` tool — the boundary over
  `YmerNode.Schedules`.

  The shape `YmerNode.Mcp.Tools.Scripts.Actions` takes: every extracted scalar is
  guarded on its head, and each guarded head is followed by a wrong-typed twin
  that answers a message rather than letting the context's own guard raise.
  `args`, `lifetime` and — on `update` — `cron_expression` are optional, so they
  are typed as they are taken, where a wrong one still has its key to name; a
  JSON null is taken as the key left out. What the values *mean* — a name's
  rule, a cron expression, a lifetime, args against the action's schema — the
  context judges, refusing each with a reason that names it.
  """
  alias YmerNode.Mcp.Tools.Helpers
  alias YmerNode.Schedules

  @optional [
    {"args", :args, &is_map/1, "an object"},
    {"lifetime", :lifetime, &is_binary/1, "a string"},
    {"cron_expression", :cron_expression, &is_binary/1, "a string"}
  ]

  def run(:list, data) when is_map(data), do: list()

  def run(
        :add,
        %{"name" => name, "script" => script, "action" => action, "cron_expression" => expression} =
          data
      )
      when is_binary(name) and is_binary(script) and is_binary(action) and is_binary(expression),
      do: add(%{name: name, script: script, action: action, cron_expression: expression}, data)

  def run(:update, %{"name" => name} = data) when is_binary(name), do: update(name, data)
  def run(:remove, %{"name" => name}) when is_binary(name), do: remove(name)

  # The wrong-typed twins, after every guarded head.
  def run(action, %{"name" => name})
      when action in [:add, :update, :remove] and not is_binary(name),
      do: Helpers.wrong_type("name", "a string", name, verb(action))

  def run(:add, %{"script" => script}) when not is_binary(script),
    do: Helpers.wrong_type("script", "a string", script, verb(:add))

  def run(:add, %{"action" => action}) when not is_binary(action),
    do: Helpers.wrong_type("action", "a string", action, verb(:add))

  def run(:add, %{"cron_expression" => expression}),
    do: Helpers.wrong_type("cron_expression", "a string", expression, verb(:add))

  defp list do
    schedules = Schedules.list()
    {:ok, %{count: length(schedules), schedules: schedules}, %{}}
  end

  defp add(attrs, data) do
    with {:ok, optional} <- optional(data, verb(:add)) do
      attrs |> Map.merge(optional) |> Schedules.add() |> answered(verb(:add))
    end
  end

  defp update(name, data) do
    with {:ok, changes} <- optional(data, verb(:update)) do
      name |> Schedules.update(changes) |> answered(verb(:update))
    end
  end

  defp remove(name) do
    case Schedules.remove(name) do
      {:ok, schedule} -> {:ok, %{removed: schedule.name}, %{}}
      {:error, reason} -> {:error, {reason, %{action_verb: verb(:remove)}}}
    end
  end

  defp optional(data, verb) do
    Enum.reduce_while(@optional, {:ok, %{}}, fn option, {:ok, taken} ->
      take(option, data, taken, verb)
    end)
  end

  defp take({key, field, type?, expected}, data, taken, verb) do
    case Map.get(data, key) do
      nil -> {:cont, {:ok, taken}}
      value -> typed(type?.(value), {key, field, expected, value}, taken, verb)
    end
  end

  defp typed(true, {_key, field, _expected, value}, taken, _verb),
    do: {:cont, {:ok, Map.put(taken, field, value)}}

  defp typed(false, {key, _field, expected, value}, _taken, verb),
    do: {:halt, Helpers.wrong_type(key, expected, value, verb)}

  defp answered({:ok, entry}, _verb), do: {:ok, entry, %{}}
  defp answered({:error, reason}, verb), do: {:error, {reason, %{action_verb: verb}}}

  defp verb(:add), do: "add a schedule"
  defp verb(:update), do: "update a schedule"
  defp verb(:remove), do: "remove a schedule"
end
