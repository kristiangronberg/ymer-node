defmodule YmerNode.Schedules.InFlightTest do
  @moduledoc """
  The process registry is VM-global and shared with every other case, so each
  case takes schedule ids and script names unique to it; that is what keeps this
  module `async: true`. An entry belongs to the process that registered it, so a
  case that needs a second registrant makes it a task. The node time zone is
  `Etc/UTC` in test, so a rendered latest end carries `Z`.
  """
  use ExUnit.Case, async: true

  alias YmerNode.Schedules.InFlight

  @until ~U[2026-09-25 10:05:00Z]

  describe "register/4" do
    test "takes the schedule's entry, and answers :in_flight while another process holds it" do
      id = unique_id()
      assert :ok = InFlight.register(id, "hourly", unique("script"), @until)

      second = Task.async(fn -> InFlight.register(id, "hourly", "other", @until) end)
      assert Task.await(second) == :in_flight
    end

    test "frees the entry at unregister/1" do
      id = unique_id()
      assert :ok = InFlight.register(id, "hourly", unique("script"), @until)
      assert :ok = InFlight.unregister(id)

      again = Task.async(fn -> InFlight.register(id, "hourly", "other", @until) end)
      assert Task.await(again) == :ok
    end

    @tag doc: """
         Two schedules that share a name at different moments — one removed
         while its run finishes, one added again under that name — are two
         schedules. A failure means the new one's firing is skipped for a run
         it never started, with nothing left to say why.
         """
    test "keeps a schedule added again under a freed name apart from the one it replaced" do
      name = unique("schedule")
      assert :ok = InFlight.register(unique_id(), name, unique("script"), @until)

      again = Task.async(fn -> InFlight.register(unique_id(), name, "other", @until) end)
      assert Task.await(again) == :ok
    end
  end

  describe "refusal/1" do
    test "names the script and asks for a retry when no firing holds the run" do
      script = unique("script")

      assert InFlight.refusal(script) ==
               {:run_in_flight, "#{script} has a run in flight; retry when it ends"}
    end

    @tag doc: """
         The refusal an edit meets while a firing's run of the script is in
         flight. A failure means the editor is told to retry with nothing
         saying why the run exists — a run nobody at the keyboard started.
         """
    test "names the schedule whose firing holds the run, and its latest end" do
      schedule = unique("schedule")
      script = unique("script")
      :ok = InFlight.register(unique_id(), schedule, script, @until)

      assert {:run_in_flight, message} = InFlight.refusal(script)
      assert message =~ "#{script} has a run in flight from schedule #{schedule}"
      assert message =~ "until 2026-09-25T10:05:00Z at the latest"
    end

    @tag doc: """
         The time a refusal gives is the one the editor retries at. A failure
         means it named a run that ends earlier than another schedule's run of
         the same script, and the retry at that time is refused again.
         """
    test "names the latest-ending schedule when several hold runs of the script" do
      script = unique("script")
      :ok = InFlight.register(unique_id(), "early", script, ~U[2026-09-25 10:01:00Z])
      :ok = InFlight.register(unique_id(), "late", script, ~U[2026-09-25 10:09:00Z])
      :ok = InFlight.register(unique_id(), "middle", script, ~U[2026-09-25 10:05:00Z])

      assert {:run_in_flight, message} = InFlight.refusal(script)
      assert message =~ "from schedule late until 2026-09-25T10:09:00Z at the latest"
    end
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
  defp unique_id, do: System.unique_integer([:positive])
end
