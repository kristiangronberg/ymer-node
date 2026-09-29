defmodule YmerNode.Repo.Migrations.AddWatchesToSchedulesTest do
  @moduledoc """
  Runs the migration that rebuilds `schedules` for watches through
  `Ecto.Migrator`, under the arrangement
  `YmerNode.Repo.Migrations.PlantExampleScriptTest` explains: a plain
  `ExUnit.Case`, `async: false`, the sandbox in `:auto` for the duration, the
  version unrecorded by `setup` and recorded again on exit, and the file loaded
  by hand on a run whose boot did not load it.

  The migration copies every row through a column list written by hand and
  makes the indexes again, so a case writes a schedule with every column set
  before `up` and reads each one back after it. Rows are written in SQL, because
  the schema in this build already describes the rebuilt table; every row a
  case writes goes with the script and the reference it deletes on exit.
  """
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias YmerNode.References
  alias YmerNode.References.Reference
  alias YmerNode.Repo
  alias YmerNode.Repo.Migrations.AddWatchesToSchedules
  alias YmerNode.Scripts.Script

  @version 20_260_929_140_000
  @path Application.app_dir(
          :ymer_node,
          "priv/repo/migrations/20260929140000_add_watches_to_schedules.exs"
        )

  @check "schedules_run_a_script_or_watch_a_reference"

  setup do
    unless Code.ensure_loaded?(AddWatchesToSchedules), do: Code.require_file(@path)

    # Registered before the sandbox mode moves, so a `setup` that fails after
    # it still puts the mode back and records the version again.
    on_exit(fn ->
      capture_log(fn -> Ecto.Migrator.up(Repo, @version, AddWatchesToSchedules, log: false) end)
      Sandbox.mode(Repo, :manual)
    end)

    Sandbox.mode(Repo, :auto)

    unrecorded = Ecto.Migrator.down(Repo, @version, AddWatchesToSchedules, log: false)
    assert unrecorded in [:ok, :already_down]

    :ok
  end

  describe "up/0" do
    @tag doc: """
         The rebuild copies rows through a column list written by hand. A
         failure means an existing install loses a schedule, or one of its
         last-run fields, or an index the name rule reads, at the upgrade.
         """
    test "keeps every column of an existing schedule, and makes the three indexes" do
      script = script!()
      insert_before_up!(script.id)

      assert :ok = Ecto.Migrator.up(Repo, @version, AddWatchesToSchedules, log: false)

      assert [
               [
                 "copied",
                 id,
                 nil,
                 "ping",
                 ~s({"url":"https://hex.pm"}),
                 "0 7 * * *",
                 "error",
                 "boom",
                 42
               ]
             ] =
               rows(
                 "SELECT name, script_id, reference_id, action, args, cron_expression, " <>
                   "last_outcome, last_message, last_run_ms FROM schedules WHERE name = 'copied'"
               )

      assert id == script.id
      assert [[fired_at, ends_at]] = rows("SELECT last_fired_at, ends_at FROM schedules")
      assert fired_at != nil and ends_at != nil

      assert Enum.sort(
               rows(
                 "SELECT name FROM sqlite_master WHERE type = 'index' AND " <>
                   "tbl_name = 'schedules' AND name NOT LIKE 'sqlite_%'"
               )
             ) ==
               [
                 ["schedules_name_index"],
                 ["schedules_reference_id_index"],
                 ["schedules_script_id_index"]
               ]
    end

    test "refuses a row naming neither a script nor a reference, both, or a script without an action" do
      assert :ok = Ecto.Migrator.up(Repo, @version, AddWatchesToSchedules, log: false)
      script = script!()
      reference = reference!()

      for {name, script_id, reference_id, action} <- [
            {"neither", nil, nil, nil},
            {"both", script.id, reference.id, "ping"},
            {"no-action", script.id, nil, nil}
          ] do
        assert {:error, %{message: "CHECK constraint failed: " <> @check}} =
                 try_insert([name, script_id, reference_id, action])
      end

      assert {:ok, _inserted} = try_insert(["watch", nil, reference.id, nil])
    end
  end

  describe "down/0" do
    test "removes every watch, keeps the script schedules, and makes script and action required again" do
      assert :ok = Ecto.Migrator.up(Repo, @version, AddWatchesToSchedules, log: false)
      script = script!()
      reference = reference!()
      assert {:ok, _kept} = try_insert(["kept", script.id, nil, "ping"])
      assert {:ok, _watch} = try_insert(["reference-#{reference.id}", nil, reference.id, nil])

      assert :ok = Ecto.Migrator.down(Repo, @version, AddWatchesToSchedules, log: false)

      assert rows("SELECT name FROM schedules") == [["kept"]]

      assert {:error, %{message: "NOT NULL constraint failed: " <> _column}} =
               Repo.query(
                 "INSERT INTO schedules (name, script_id, action, args, cron_expression, " <>
                   "ends_at, inserted_at, updated_at) VALUES (?, ?, NULL, '{}', '0 7 * * *', " <>
                   "?, ?, ?)",
                 ["no-action", script.id, now(), now(), now()]
               )
    end
  end

  # A schedule of a script in the table as it was before `up`, every column
  # set, the last run's included.
  defp insert_before_up!(script_id) do
    Repo.query!(
      "INSERT INTO schedules (name, script_id, action, args, cron_expression, ends_at, " <>
        "last_fired_at, last_outcome, last_message, last_run_ms, inserted_at, updated_at) " <>
        "VALUES ('copied', ?, 'ping', ?, '0 7 * * *', ?, ?, 'error', 'boom', 42, ?, ?)",
      [script_id, ~s({"url":"https://hex.pm"}), now(), now(), now(), now()]
    )
  end

  # A row in the rebuilt table, where `reference_id` exists.
  defp try_insert([name, script_id, reference_id, action]) do
    Repo.query(
      "INSERT INTO schedules (name, script_id, reference_id, action, args, cron_expression, " <>
        "ends_at, inserted_at, updated_at) VALUES (?, ?, ?, ?, '{}', '0 7 * * *', ?, ?, ?)",
      [name, script_id, reference_id, action, now(), now(), now()]
    )
  end

  defp rows(sql), do: Repo.query!(sql).rows

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp script! do
    name = "rebuilt#{System.unique_integer([:positive])}"
    code = "defmodule Script.Absent do\nend\n"
    hash = Script.hash(code)

    row =
      Repo.insert!(
        Script.changeset(%Script{}, %{
          name: name,
          code: code,
          code_hash: hash,
          accepted_hash: hash,
          accepted_at: now(),
          origin: "authored",
          contract: YmerNode.Script.contract(),
          description: name,
          declarations: %{"hosts" => [], "url_action" => nil, "secrets" => []}
        })
      )

    on_exit(fn -> Repo.delete_all(from script in Script, where: script.id == ^row.id) end)
    row
  end

  defp reference! do
    {:ok, reference} =
      References.create_reference(%{
        title: "A watched page",
        uri: "https://rebuilt.example.test/#{System.unique_integer([:positive])}"
      })

    on_exit(fn -> Repo.delete_all(from r in Reference, where: r.id == ^reference.id) end)
    reference
  end
end
