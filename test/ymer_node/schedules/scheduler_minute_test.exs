defmodule YmerNode.Schedules.SchedulerMinuteTest do
  @moduledoc """
  The one case that runs the scheduler's minute for real: `handle_info/2` called
  by hand, with a real accepted script and a real schedule, so the firing it
  starts goes through the firing supervisor, `YmerNode.Schedules.fire/2` and the
  runner. The process itself is off in test, so nothing else ticks.

  Not async, because the firing's task reads the node database from a process
  of its own and needs the shared sandbox. The call re-arms the next minute
  against this case's own process, which ends before the message arrives. The
  node time zone is `Etc/UTC` in test, so this case pins no zone rule —
  `YmerNode.Schedules.SchedulerTest` does.
  """
  use YmerNode.DataCase

  alias YmerNode.Schedules
  alias YmerNode.Schedules.Scheduler
  alias YmerNode.Scripts
  alias YmerNode.Scripts.Compiler

  describe "handle_info/2" do
    @tag doc: """
         The wiring nothing else reaches: the minute read off the clock, the
         active schedules read, one task started per due schedule under the
         firing supervisor, and the last run kept. A failure with no last run
         means a firing never started — a firing supervisor missing from the
         tree or renamed, or a due schedule the minute dropped.
         """
    test "fires a due schedule in a task of its own, and keeps its last run" do
      segment = "Minute#{System.unique_integer([:positive])}"
      on_exit(fn -> Compiler.purge(Module.concat(["Script", segment])) end)
      assert {:ok, script} = Scripts.create(code(segment))

      {:ok, _entry} =
        Schedules.add(%{
          name: "every-minute",
          script: script.name,
          action: "ping",
          cron_expression: "* * * * *"
        })

      before = minute_now()
      assert {:noreply, %{carried: carried}} = Scheduler.handle_info(:minute, %{carried: %{}})
      assert map_size(carried) == 1

      assert %{outcome: "ok", fired_at: fired_at} = wait_for_last_run("every-minute")
      {:ok, fired_at, 0} = DateTime.from_iso8601(fired_at)
      assert fired_at in [before, minute_now()]
    end
  end

  defp minute_now, do: %{DateTime.truncate(DateTime.utc_now(), :second) | second: 0}

  defp wait_for_last_run(name, attempts \\ 200) do
    case Enum.find(Schedules.list(), &(&1.name == name)) do
      %{last_run: %{} = last_run} ->
        last_run

      _no_run_yet when attempts > 0 ->
        Process.sleep(10)
        wait_for_last_run(name, attempts - 1)

      _no_run_yet ->
        flunk("no last run was kept for #{name}")
    end
  end

  defp code(segment) do
    """
    defmodule Script.#{segment} do
      use YmerNode.Script

      @impl true
      def description, do: "the #{segment} script"

      @impl true
      def actions, do: %{ping: %{description: "answers", properties: %{}, write: false}}

      @impl true
      def declarations, do: %{hosts: [], url_action: nil, secrets: []}

      @impl true
      def run(:ping, _args, _context), do: {:ok, %{"pong" => true}}
    end
    """
  end
end
