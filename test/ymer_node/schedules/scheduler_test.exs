defmodule YmerNode.Schedules.SchedulerTest do
  @moduledoc """
  Drives `YmerNode.Schedules.Scheduler.plan/4` alone — the process itself is off
  in test — feeding it minute after minute the way the process would, with the
  carried firings threaded through. The schedules are bare structs: `plan/4`
  reads an id and a cron expression and touches no database, so the module is
  `async: true`.
  """
  use ExUnit.Case, async: true

  alias YmerNode.Schedules.Schedule
  alias YmerNode.Schedules.Scheduler

  @helsinki "Europe/Helsinki"

  describe "plan/4" do
    test "fires a schedule in the minute it comes due, and not in the minutes around it" do
      assert fired("0 7 * * *", "Etc/UTC", ~U[2026-09-26 06:58:00Z], ~U[2026-09-26 07:02:00Z]) ==
               [~U[2026-09-26 07:00:00Z]]
    end

    test "fires in the first minute it is asked about, when that minute is due" do
      schedule = schedule("0 7 * * *")

      assert {[^schedule], _carried} =
               Scheduler.plan(%{}, [schedule], ~U[2026-09-26 07:00:00Z], "Etc/UTC")
    end

    @tag doc: """
         The skip rule for a node that was not up: a laptop asleep at 07:00
         wakes at 07:20. A failure listing 07:20 means a missed firing was
         caught up late — the run the rule exists to prevent, started before
         the machine is ready for it.
         """
    test "skips a firing the node was not up for, and fires the next one on time" do
      schedule = schedule("0 7 * * *")
      {[], carried} = Scheduler.plan(%{}, [schedule], ~U[2026-09-26 06:59:00Z], "Etc/UTC")

      assert {[], carried} =
               Scheduler.plan(carried, [schedule], ~U[2026-09-26 07:20:00Z], "Etc/UTC")

      assert {[^schedule], _carried} =
               Scheduler.plan(carried, [schedule], ~U[2026-09-27 07:00:00Z], "Etc/UTC")
    end

    @tag doc: """
         Helsinki falls back at 04:00 EEST on 25 October 2026, so 03:30 occurs
         at 00:30 and again at 01:30 UTC. A failure listing 01:30 means the
         second pass of the repeated hour came due, and a once-a-day schedule
         fired twice.
         """
    test "fires a time in the hour a fall-back repeats once, on its first pass" do
      assert fired("30 3 * * *", @helsinki, ~U[2026-10-24 23:00:00Z], ~U[2026-10-25 03:00:00Z]) ==
               [~U[2026-10-25 00:30:00Z]]
    end

    test "keeps an interval cadence's first pass through the repeated hour and skips its second" do
      assert fired("*/15 * * * *", @helsinki, ~U[2026-10-24 23:50:00Z], ~U[2026-10-25 02:05:00Z]) ==
               [
                 ~U[2026-10-25 00:00:00Z],
                 ~U[2026-10-25 00:15:00Z],
                 ~U[2026-10-25 00:30:00Z],
                 ~U[2026-10-25 00:45:00Z],
                 ~U[2026-10-25 02:00:00Z]
               ]
    end

    test "keeps an every-minute cadence's first pass through the repeated hour and skips its second" do
      assert fired("* * * * *", @helsinki, ~U[2026-10-25 00:58:00Z], ~U[2026-10-25 02:01:00Z]) ==
               [
                 ~U[2026-10-25 00:58:00Z],
                 ~U[2026-10-25 00:59:00Z],
                 ~U[2026-10-25 02:00:00Z],
                 ~U[2026-10-25 02:01:00Z]
               ]
    end

    @tag doc: """
         What is carried lives in the process alone, so a restart asks afresh
         from the minute it comes up. A failure means a scheduler that came up
         in the minute of 03:30's second pass fired a time its predecessor had
         already fired on the first.
         """
    test "fires nothing on the second pass when first asked in that very minute" do
      schedule = schedule("30 3 * * *")

      assert {[], _carried} = Scheduler.plan(%{}, [schedule], ~U[2026-10-25 01:30:00Z], @helsinki)
    end

    test "does not fire a time in the hour a spring-forward skips" do
      assert fired("30 3 * * *", @helsinki, ~U[2027-03-27 23:00:00Z], ~U[2027-03-28 03:00:00Z]) ==
               []
    end

    test "finds a changed cron expression afresh" do
      schedule = schedule("0 7 * * *")
      {[], carried} = Scheduler.plan(%{}, [schedule], ~U[2026-09-26 06:59:00Z], "Etc/UTC")
      changed = %{schedule | cron_expression: "0 8 * * *"}

      assert {[], carried} =
               Scheduler.plan(carried, [changed], ~U[2026-09-26 07:00:00Z], "Etc/UTC")

      assert {[^changed], _carried} =
               Scheduler.plan(carried, [changed], ~U[2026-09-26 08:00:00Z], "Etc/UTC")
    end

    test "carries nothing for a schedule no longer active" do
      schedule = schedule("0 7 * * *")
      {[], carried} = Scheduler.plan(%{}, [schedule], ~U[2026-09-26 06:59:00Z], "Etc/UTC")

      assert Scheduler.plan(carried, [], ~U[2026-09-26 07:00:00Z], "Etc/UTC") == {[], %{}}
    end
  end

  defp schedule(expression) do
    %Schedule{id: System.unique_integer([:positive]), name: "s", cron_expression: expression}
  end

  # Every minute from `from` to `to`, fed through `plan/4` as the process
  # would; answers the minutes a firing came due.
  defp fired(expression, zone, from, to) do
    schedule = schedule(expression)

    from
    |> Stream.iterate(&DateTime.add(&1, 60, :second))
    |> Enum.take_while(&(DateTime.compare(&1, to) != :gt))
    |> Enum.reduce({[], %{}}, fn minute, {fired, carried} ->
      {due, carried} = Scheduler.plan(carried, [schedule], minute, zone)
      {fired ++ Enum.map(due, fn _schedule -> minute end), carried}
    end)
    |> elem(0)
  end
end
