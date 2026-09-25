defmodule YmerNode.Schedules.ScheduleTest do
  @moduledoc """
  Writes rows straight through the schema, beneath `YmerNode.Schedules`: what is
  pinned here is the table's own rules — the unique name and the cascade — which
  hold whatever door a row came through. The script rows are inserted bare, with
  code nothing compiles, because no case here runs anything.
  """
  use YmerNode.DataCase

  alias YmerNode.Schedules.Schedule
  alias YmerNode.Scripts.Script

  doctest Schedule

  describe "the schedules table" do
    @tag doc: """
         The database rule that makes removing a script remove its schedules.
         A failure means SQLite's foreign keys are off for the node database,
         or the migration lost its `on_delete` — and every door removing a
         script would then leave schedules firing at a script that is gone.
         """
    test "deletes a script's schedules with the script" do
      script = script!()
      schedule!(script, "morning-report")

      Repo.delete!(script)

      assert Repo.aggregate(Schedule, :count) == 0
    end

    test "refuses a second schedule of one name" do
      script = script!()
      schedule!(script, "morning-report")

      assert {:error, changeset} =
               Repo.insert(Schedule.changeset(%Schedule{}, attrs(script, "morning-report")))

      assert %{name: ["has already been taken"]} = errors_on(changeset)
    end

    test "round-trips args with string keys" do
      schedule = schedule!(script!(), "weekly-summary")

      assert %Schedule{args: %{"project" => "ONEF"}} = Repo.get!(Schedule, schedule.id)
    end
  end

  defp script! do
    code = "defmodule Script.Bare#{System.unique_integer([:positive])} do\nend\n"

    %Script{}
    |> Script.changeset(%{
      name: "bare_#{System.unique_integer([:positive])}",
      code: code,
      code_hash: Script.hash(code),
      accepted_hash: Script.hash(code),
      origin: "authored",
      contract: 1,
      description: "bare",
      declarations: %{"hosts" => []}
    })
    |> Repo.insert!()
  end

  defp schedule!(script, name) do
    %Schedule{}
    |> Schedule.changeset(attrs(script, name))
    |> Repo.insert!()
  end

  defp attrs(script, name) do
    %{
      name: name,
      script_id: script.id,
      action: "report",
      args: %{project: "ONEF"},
      cron_expression: "0 7 * * *",
      ends_at: ~U[2026-12-30 00:00:00Z]
    }
  end
end
