defmodule YmerNode.SchedulesTest do
  @moduledoc """
  Every case goes through `YmerNode.Scripts` to create the script it schedules,
  so the sandbox owns it and the module is not async; each fixture takes a module
  name unique to its case and purges its own tree.

  The node time zone is `Etc/UTC` in test, so every time an answer carries ends
  in `Z`; the zone-bearing rules are pinned beneath this module, in
  `YmerNode.Schedules.CronTest`, `YmerNode.Schedules.LifetimeTest` and
  `YmerNode.Schedules.SchedulerTest`. `fire/2` is called in the case's own
  process, which is where the scheduler's task would call it.
  """
  use YmerNode.DataCase

  alias YmerNode.Schedules
  alias YmerNode.Schedules.InFlight
  alias YmerNode.Schedules.Schedule
  alias YmerNode.Scripts
  alias YmerNode.Scripts.Compiler
  alias YmerNode.Scripts.Runner
  alias YmerNode.Scripts.Script

  describe "add/1" do
    test "answers the schedule with its end, 90 days out by default, and its next firing" do
      script = create!(segment())

      assert {:ok, entry} = Schedules.add(attrs(script, "morning-report"))

      assert %{state: "active", script: name, action: "ping", last_run: nil} = entry
      assert name == script.name
      assert days_from_now(entry.ends_at) in 89..90
      assert {:ok, %DateTime{hour: 7, minute: 0}, 0} = DateTime.from_iso8601(entry.next_firing)
    end

    test "cuts a lifetime past the ceiling to 90 days" do
      script = create!(segment())

      assert {:ok, entry} = Schedules.add(Map.put(attrs(script, "yearly"), :lifetime, "P1Y"))
      assert days_from_now(entry.ends_at) in 89..90
    end

    test "refuses at add what a firing would meet, each with its own reason" do
      script = create!(segment())

      refusals = [
        {%{name: "Morning"}, :invalid_name},
        {%{cron_expression: "* * *"}, :invalid_cron_expression},
        {%{lifetime: "2026-12-31"}, :invalid_lifetime},
        {%{script: "absent"}, :not_found},
        {%{action: "absent"}, :unknown_action},
        {%{action: "fetch", args: %{}}, :invalid_args}
      ]

      for {override, reason} <- refusals do
        assert {:error, {^reason, _detail}} =
                 Schedules.add(Map.merge(attrs(script, "refused"), override)),
               inspect(override)
      end

      assert Schedules.list() == []
    end

    test "refuses a name that is taken" do
      script = create!(segment())
      {:ok, _entry} = Schedules.add(attrs(script, "morning-report"))

      assert {:error, {:name_taken, message}} = Schedules.add(attrs(script, "morning-report"))
      assert message =~ "update it"
    end

    test "refuses a script whose row is gone while its module is still loaded" do
      script = create!(segment())
      {1, _rows} = Repo.delete_all(from s in Script, where: s.id == ^script.id)

      assert {:error, {:not_found, "no script named " <> _name}} =
               Schedules.add(attrs(script, "morning-report"))
    end

    test "refuses a script that is not accepted at the code it holds" do
      script = create!(segment())
      Repo.update!(Script.changeset(script, %{accepted_hash: "stale"}))

      assert {:error, {:not_accepted, _detail}} = Schedules.add(attrs(script, "morning-report"))
    end
  end

  describe "list/0" do
    test "answers every schedule by name, an expired one as expired with no next firing" do
      script = create!(segment())
      {:ok, _entry} = Schedules.add(attrs(script, "weekly-summary"))
      {:ok, _entry} = Schedules.add(attrs(script, "morning-report"))
      expire!("weekly-summary")

      assert [%{name: "morning-report", state: "active"}, expired] = Schedules.list()
      assert %{name: "weekly-summary", state: "expired", next_firing: nil} = expired
      assert expired.ends_at == "2026-01-01T00:00:00Z"
    end

    @tag doc: """
         A row stored under an older, looser rule than the running code's. A
         failure means one such row fails the whole read, and no schedule on
         the node can be listed until it is removed by hand.
         """
    test "answers a row whose stored expression no longer parses, with no next firing" do
      script = create!(segment())
      {:ok, _entry} = Schedules.add(attrs(script, "weekly-summary"))
      {:ok, _entry} = Schedules.add(attrs(script, "morning-report"))

      {1, _rows} =
        Repo.update_all(from(s in Schedule, where: s.name == "weekly-summary"),
          set: [cron_expression: "* * *"]
        )

      assert [%{name: "morning-report", next_firing: next}, stale] = Schedules.list()
      assert is_binary(next)
      assert %{name: "weekly-summary", state: "active", next_firing: nil} = stale
    end
  end

  describe "update/2" do
    test "changes the cron expression and leaves the end where it stands" do
      script = create!(segment())
      {:ok, added} = Schedules.add(Map.put(attrs(script, "morning-report"), :lifetime, "P30D"))

      assert {:ok, updated} = Schedules.update("morning-report", %{cron_expression: "30 8 * * *"})
      assert updated.cron_expression == "30 8 * * *"
      assert updated.ends_at == added.ends_at
    end

    test "reads a lifetime from the update, renewing an expired schedule" do
      script = create!(segment())
      {:ok, _added} = Schedules.add(attrs(script, "morning-report"))
      expire!("morning-report")

      assert {:ok, renewed} = Schedules.update("morning-report", %{lifetime: "P30D"})
      assert renewed.state == "active"
      assert days_from_now(renewed.ends_at) in 29..30
    end

    test "refuses args the action's schema rejects, and keeps the schedule as it was" do
      script = create!(segment())

      {:ok, _added} =
        Schedules.add(%{
          attrs(script, "fetcher")
          | action: "fetch",
            args: %{"url" => "https://hex.pm"}
        })

      assert {:error, {:invalid_args, _detail}} = Schedules.update("fetcher", %{args: %{}})
      assert [%{args: %{"url" => "https://hex.pm"}}] = Schedules.list()
    end

    test "refuses a schedule that is not there" do
      assert {:error, {:not_found, "no schedule named absent"}} = Schedules.update("absent", %{})
    end
  end

  describe "remove/1" do
    test "deletes the schedule" do
      script = create!(segment())
      {:ok, _added} = Schedules.add(attrs(script, "morning-report"))

      assert {:ok, %{name: "morning-report"}} = Schedules.remove("morning-report")
      assert Schedules.list() == []
    end

    test "refuses a schedule that is not there" do
      assert {:error, {:not_found, _detail}} = Schedules.remove("absent")
    end

    test "goes with its script when the script is removed" do
      script = create!(segment())
      {:ok, _added} = Schedules.add(attrs(script, "morning-report"))

      assert {:ok, _removed} = Scripts.remove(script.name)
      assert Schedules.list() == []
    end
  end

  describe "active/1" do
    test "answers the schedules inside their lifetime" do
      script = create!(segment())
      {:ok, _added} = Schedules.add(attrs(script, "morning-report"))
      {:ok, _added} = Schedules.add(attrs(script, "weekly-summary"))
      expire!("weekly-summary")

      assert [%{name: "morning-report"}] = Schedules.active(DateTime.utc_now())
    end
  end

  describe "fire/2" do
    test "runs the action and keeps the last run" do
      script = create!(segment())
      {:ok, _added} = Schedules.add(attrs(script, "morning-report"))

      assert Schedules.fire(active!("morning-report"), ~U[2026-09-26 07:00:00Z]) == "ok"

      assert [%{last_run: last_run}] = Schedules.list()
      assert %{fired_at: "2026-09-26T07:00:00Z", outcome: "ok", message: nil} = last_run
      assert is_integer(last_run.took_ms)
    end

    test "keeps a refusal the run meets as refused, with the runner's message" do
      script = create!(segment())
      {:ok, _added} = Schedules.add(attrs(script, "morning-report"))
      Repo.update!(Script.changeset(script, %{accepted_hash: "stale"}))

      assert Schedules.fire(active!("morning-report"), ~U[2026-09-26 07:00:00Z]) == "refused"

      assert [%{last_run: %{outcome: "refused", message: message}}] = Schedules.list()
      assert message =~ "accept it before running it"
    end

    test "keeps a script's own failure as error" do
      script = create!(segment())
      {:ok, _added} = Schedules.add(%{attrs(script, "failing") | action: "fails"})

      assert Schedules.fire(active!("failing"), ~U[2026-09-26 07:00:00Z]) == "error"

      assert [%{last_run: %{outcome: "error", message: message}}] = Schedules.list()
      assert message =~ ":boom"
    end

    @tag doc: """
         The per-schedule overlap rule. A failure means a firing started a
         second run while the schedule's previous one was still going — the
         pile-up a run outlasting its cadence would build with nothing to
         stop it.
         """
    test "skips, keeping nothing, while the schedule's previous run is in flight" do
      script = create!(segment())
      {:ok, _added} = Schedules.add(attrs(script, "morning-report"))
      schedule = active!("morning-report")
      :ok = InFlight.register(schedule.id, schedule.name, script.name, ~U[2026-09-26 07:05:00Z])

      assert Schedules.fire(schedule, ~U[2026-09-26 07:00:00Z]) == :skipped
      assert [%{last_run: nil}] = Schedules.list()
    end

    @tag doc: """
         A schedule removed while its run finishes frees its name at once. A
         failure means the schedule added again under that name had its
         firing skipped for the old one's run, with no trace to say why.
         """
    test "fires a schedule added again under a name whose old run is still in flight" do
      script = create!(segment())
      {:ok, _added} = Schedules.add(attrs(script, "morning-report"))
      old = active!("morning-report")
      :ok = InFlight.register(old.id, old.name, script.name, ~U[2026-09-26 07:05:00Z])

      {:ok, _removed} = Schedules.remove("morning-report")
      {:ok, _added} = Schedules.add(attrs(script, "morning-report"))

      assert Schedules.fire(active!("morning-report"), ~U[2026-09-26 07:00:00Z]) == "ok"
    end

    @tag doc: """
         The refusal a firing's own run gives an edit, end to end: the latest
         end computed from the action's deadline and rendered in the node's
         time zone. A failure on the pattern means that end is shown with a
         fraction of a second, or not at all.
         """
    test "holds its script against edits while it runs, naming itself and a whole-second end" do
      script = create!(segment())
      {:ok, _added} = Schedules.add(%{attrs(script, "napper") | action: "naps"})
      firing = Task.async(fn -> Schedules.fire(active!("napper"), ~U[2026-09-26 07:00:00Z]) end)

      assert wait_until(fn -> Runner.in_flight?(script.name) end)

      assert {:error, {:run_in_flight, message}} = Scripts.remove(script.name)

      assert message =~
               ~r/from schedule napper until \d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ at the latest/

      assert Task.await(firing) == "ok"
    end
  end

  defp segment, do: "Sched#{System.unique_integer([:positive])}"

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() ->
        true

      attempts == 0 ->
        false

      true ->
        Process.sleep(10)
        wait_until(fun, attempts - 1)
    end
  end

  defp attrs(script, name) do
    %{name: name, script: script.name, action: "ping", args: %{}, cron_expression: "0 7 * * *"}
  end

  defp active!(name), do: Enum.find(Schedules.active(DateTime.utc_now()), &(&1.name == name))

  defp expire!(name) do
    {1, _rows} =
      Repo.update_all(from(s in Schedule, where: s.name == ^name),
        set: [ends_at: ~U[2026-01-01 00:00:00Z]]
      )
  end

  defp days_from_now(iso) do
    {:ok, at, _offset} = DateTime.from_iso8601(iso)
    DateTime.diff(at, DateTime.utc_now(), :day)
  end

  defp create!(segment) do
    on_exit(fn -> Compiler.purge(Module.concat(["Script", segment])) end)

    assert {:ok, script} = Scripts.create(code(segment))
    script
  end

  defp code(segment) do
    """
    defmodule Script.#{segment} do
      use YmerNode.Script

      @impl true
      def description, do: "the #{segment} script"

      @impl true
      def actions do
        %{
          fetch: %{
            description: "fetches a url",
            properties: %{"url" => %{"type" => "string"}},
            required: ["url"],
            write: false
          },
          fails: %{description: "answers an error", properties: %{}, write: false},
          naps: %{description: "sleeps", properties: %{}, write: false, timeout: 5_000},
          ping: %{description: "answers", properties: %{}, write: false}
        }
      end

      @impl true
      def declarations, do: %{hosts: [], url_action: nil, secrets: []}

      @impl true
      def run(:ping, _args, _context), do: {:ok, %{"pong" => true}}
      def run(:fetch, %{"url" => url}, _context), do: {:ok, %{"url" => url}}
      def run(:fails, _args, _context), do: {:error, :boom}

      def run(:naps, _args, _context) do
        Process.sleep(300)
        {:ok, %{"slept" => true}}
      end
    end
    """
  end
end
