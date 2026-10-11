defmodule YmerNode.Mcp.Tools.Messages.Actions do
  @moduledoc """
  Action implementations for the `messages` tool — the boundary over
  `YmerNode.Messages`.

  The shape `YmerNode.Mcp.Tools.Schedules.Actions` takes: every required scalar
  is guarded on its head, each guarded head is followed by a wrong-typed twin
  that answers an error message, and the optional keys are typed as they are taken, a
  `nil` taken as the key left out — on the wire the value gate refuses a JSON
  null first, so that serves direct calls. `thread` on `read` is a string or a list
  of strings, so it is checked as either. What a since means, and every answer's
  shape, the context decides.
  """
  alias YmerNode.Mcp.Tools.Helpers
  alias YmerNode.Messages

  @optional [
    {"thread", :thread, :threads, "a string or a list of strings"},
    {"last", :last, :integer, "an integer"},
    {"before", :before, :integer, "an integer"},
    {"since", :since, :string, "a string"}
  ]

  def run(:send, %{"as" => handle, "thread" => thread, "body" => body})
      when is_binary(handle) and is_binary(thread) and is_binary(body),
      do: handle |> Messages.send(thread, body) |> answered(verb(:send))

  def run(:check, %{"as" => handle} = data) when is_binary(handle), do: check(handle, data)
  def run(:read, data) when is_map(data), do: read(data)

  # The wrong-typed twins, after every guarded head.
  def run(action, %{"as" => handle}) when action in [:send, :check] and not is_binary(handle),
    do: Helpers.wrong_type("as", "a string", handle, verb(action))

  def run(:send, %{"thread" => thread}) when not is_binary(thread),
    do: Helpers.wrong_type("thread", "a string", thread, verb(:send))

  def run(:send, %{"body" => body}),
    do: Helpers.wrong_type("body", "a string", body, verb(:send))

  defp check(handle, data) do
    case Map.get(data, "thread") do
      nil ->
        handle |> Messages.check(nil) |> answered(verb(:check))

      thread when is_binary(thread) ->
        handle |> Messages.check(thread) |> answered(verb(:check))

      thread ->
        Helpers.wrong_type("thread", "a string", thread, verb(:check))
    end
  end

  defp read(data) do
    with {:ok, filters} <- optional(data) do
      filters |> Messages.read() |> answered(verb(:read))
    end
  end

  defp optional(data) do
    Enum.reduce_while(@optional, {:ok, %{}}, fn option, {:ok, taken} ->
      take(option, data, taken)
    end)
  end

  defp take({key, field, type, expected}, data, taken) do
    case Map.get(data, key) do
      nil -> {:cont, {:ok, taken}}
      value -> typed(of_type?(type, value), {key, field, expected, value}, taken)
    end
  end

  defp of_type?(:string, value), do: is_binary(value)
  defp of_type?(:integer, value), do: is_integer(value)
  defp of_type?(:threads, [_ | _] = threads), do: Enum.all?(threads, &is_binary/1)
  defp of_type?(:threads, thread), do: is_binary(thread)

  defp typed(true, {_key, field, _expected, value}, taken),
    do: {:cont, {:ok, Map.put(taken, field, value)}}

  defp typed(false, {key, _field, expected, value}, _taken),
    do: {:halt, Helpers.wrong_type(key, expected, value, verb(:read))}

  defp answered({:ok, answer}, _verb), do: {:ok, answer, %{}}
  defp answered({:error, reason}, verb), do: {:error, {reason, %{action_verb: verb}}}

  defp verb(:send), do: "send a message"
  defp verb(:check), do: "check messages"
  defp verb(:read), do: "read messages"
end
