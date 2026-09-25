defmodule YmerNode.Schedules.InFlight do
  @moduledoc """
  Which schedules have a run in flight right now, and until when at the latest —
  a process registry of its own, unique by schedule, whose entry a firing takes
  for as long as its run lasts.

  It answers two questions. The next firing of a schedule whose previous run is
  still going asks it whether to skip, and the answer has to be per schedule:
  the runner's own process registry, `YmerNode.Scripts.Runs`, is keyed by
  script, and two schedules of one script, or a schedule and a manual run, must
  never block each other. And a door that replaces or removes a script's code,
  refused because a run of it is in flight, asks it which schedule started that
  run, so the refusal can say — an edit refused for a run nobody at the keyboard
  started would otherwise explain nothing.

  An entry is keyed by the schedule's row id and carries its name beside it,
  never keyed by the name: `YmerNode.Schedules.remove/1` frees a name while a
  firing's run may still be finishing, and a schedule added again under that
  name is another schedule, whose first firing must not be skipped for a run it
  never started.

  The refusal is composed here, rather than in `YmerNode.Scripts`, because two
  places give it: each door's early look, and `YmerNode.Scripts.Loader`'s look in
  the message that purges, which is the one that holds. This module depends on
  neither, so both can reach it. When several schedules of one script have a run
  in flight at once, the refusal names the one whose run may last longest, so
  the time it gives is one the editor can retry at. A manual run keeps no latest
  end anywhere, so a refusal while only manual runs are in flight asks for a
  retry when the run ends.

  An entry is dropped when its process ends, like any process registry entry, so
  a firing that dies leaves nothing behind. The latest end is carried as a
  `DateTime` and rendered only in the refusal, in the node's time zone.
  """
  alias YmerNode.Script.Context

  @registry __MODULE__

  @doc """
  Takes the entry for one firing of the schedule `schedule_id` in the calling
  process — `:ok` — or answers `:in_flight` while another process holds it.
  `name` is the schedule's name, which the refusal gives.
  """
  def register(schedule_id, name, script, %DateTime{} = until)
      when is_integer(schedule_id) and is_binary(name) and is_binary(script) do
    entry = %{name: name, script: script, until: until}

    case Registry.register(@registry, schedule_id, entry) do
      {:ok, _owner} -> :ok
      {:error, {:already_registered, _owner}} -> :in_flight
    end
  end

  @doc "Drops the calling process's entry for the schedule `schedule_id`."
  def unregister(schedule_id) when is_integer(schedule_id),
    do: Registry.unregister(@registry, schedule_id)

  @doc """
  The refusal every door that replaces or removes a script's code gives while a
  run of it is in flight — naming the schedule and the run's latest end when a
  firing started it, the latest-ending one when several did.
  """
  def refusal(script) when is_binary(script) do
    case started_by(script) do
      nil ->
        {:run_in_flight, "#{script} has a run in flight; retry when it ends"}

      %{name: schedule, until: until} ->
        {:run_in_flight,
         "#{script} has a run in flight from schedule #{schedule} until #{render(until)} " <>
           "at the latest; retry then"}
    end
  end

  defp started_by(script) do
    @registry
    |> Registry.select([{{:_, :_, :"$1"}, [], [:"$1"]}])
    |> Enum.filter(&(&1.script == script))
    |> Enum.max_by(& &1.until, DateTime, fn -> nil end)
  end

  defp render(until) do
    until |> DateTime.shift_zone!(Context.time_zone()) |> DateTime.to_iso8601()
  end
end
