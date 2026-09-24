defmodule YmerNode.Repo.Migrations.PlantExampleScriptTest do
  @moduledoc """
  Runs the migration that plants the example script through `Ecto.Migrator`,
  the way the boot runs it — `down/0` calls `repo/0`, which resolves only inside
  a migrator's runner — and so needs what `YmerNode.RepoTest` needs: a plain
  `ExUnit.Case`, `async: false`, and the sandbox in `:auto` for the duration,
  since under `:manual` the migrator's task cannot check out a connection.
  Nothing is rolled back, so `setup`'s exit puts the database back itself: the
  planted row gone, the version recorded, and every row a case inserted
  deleted by id.

  The suite's database has this version recorded before any case runs, and
  `Ecto.Migrator.up/4` answers `:already_up` without running a recorded one —
  so `setup` unrecords it by running `down` first, and its exit records it
  again under the suite's own `plant_example: false`, which plants nothing.
  The boot compiles only the pending migration files, so on a run where the
  version was already recorded the module is not loaded at all; `setup` loads
  the file itself when it is not.

  `config/test.exs` turns the planting off for the same reason the loader's
  boot compile is off; the cases here turn it on, and are the one place in the
  suite that does. Each case compiles `Script.Hex` through the migration; the
  module is purged on exit as `YmerNode.ScriptsTest` purges it, and this
  module runs after every async one, `Script.HexTest` included.
  """
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias YmerNode.Repo
  alias YmerNode.Repo.Migrations.PlantExampleScript
  alias YmerNode.Scripts
  alias YmerNode.Scripts.Compiler
  alias YmerNode.Scripts.Script

  @version 20_260_911_120_000
  @path Application.app_dir(
          :ymer_node,
          "priv/repo/migrations/20260911120000_plant_example_script.exs"
        )

  setup do
    unless Code.ensure_loaded?(PlantExampleScript), do: Code.require_file(@path)

    config = Application.get_env(:ymer_node, Scripts, [])

    # Registered BEFORE anything global is mutated. The two mutations below and
    # the migrator call between them can each fail — a raise, or a red assert —
    # and ExUnit abandons the rest of `setup` when they do; a restorer
    # registered after them would never be registered at all, leaving the
    # sandbox `:auto` and the planting on for every module that runs after this
    # one. One red case would then be a red suite.
    on_exit(fn ->
      Ecto.Migrator.down(Repo, @version, PlantExampleScript, log: false)
      Application.put_env(:ymer_node, Scripts, config)
      # With a later migration recorded, the migrator warns that an older one
      # is running; here that is the arrangement, not a hazard.
      capture_log(fn -> Ecto.Migrator.up(Repo, @version, PlantExampleScript, log: false) end)
      Compiler.purge(Module.concat(["Script", "Hex"]))
      Sandbox.mode(Repo, :manual)
    end)

    Sandbox.mode(Repo, :auto)
    Application.put_env(:ymer_node, Scripts, Keyword.put(config, :plant_example, true))

    unrecorded = Ecto.Migrator.down(Repo, @version, PlantExampleScript, log: false)
    assert unrecorded in [:ok, :already_down]

    :ok
  end

  describe "up/0" do
    test "plants the example as an accepted row of origin shipped" do
      assert :ok = Ecto.Migrator.up(Repo, @version, PlantExampleScript, log: false)

      assert %Script{origin: "shipped"} = planted = Repo.get_by(Script, name: "hex")
      assert Script.accepted?(planted)
      assert planted.code == File.read!(Scripts.example_path())
    end

    test "plants nothing where the configuration turns the planting off" do
      Application.put_env(:ymer_node, Scripts, plant_example: false)

      assert :ok = Ecto.Migrator.up(Repo, @version, PlantExampleScript, log: false)
      assert Repo.get_by(Script, name: "hex") == nil
    end

    @tag doc: """
         The migration reads the host refusal ahead of its raise clause, and the
         two have one shape. A failure that raises means the clauses were
         reordered, and an install whose operator already claims hex.pm dies at
         every boot; one that plants means the host rule left the build's door.
         """
    test "plants nothing, and logs why, where an accepted script claims the example's host" do
      claimant = accepted_row!(["hex.pm"])

      log =
        capture_log(fn ->
          assert :ok = Ecto.Migrator.up(Repo, @version, PlantExampleScript, log: false)
        end)

      assert log =~ "the example script was not planted"
      assert log =~ "hex.pm is already claimed by the accepted script #{claimant.name}"
      assert Repo.get_by(Script, name: "hex") == nil
      assert Repo.get!(Script, claimant.id).declarations["hosts"] == ["hex.pm"]
    end
  end

  describe "down/0" do
    test "removes the row up planted, and no other" do
      kept = accepted_row!([])
      assert :ok = Ecto.Migrator.up(Repo, @version, PlantExampleScript, log: false)
      assert %Script{} = Repo.get_by(Script, name: "hex")

      assert :ok = Ecto.Migrator.down(Repo, @version, PlantExampleScript, log: false)

      assert Repo.get_by(Script, name: "hex") == nil
      assert Repo.get!(Script, kept.id).origin == "authored"
    end
  end

  # An accepted row as the references seam reads it — no compile, no loader:
  # the host rule reads rows, and rows are all the migration's door meets.
  defp accepted_row!(hosts) do
    name = "claimant#{System.unique_integer([:positive])}"
    code = "defmodule Script.Absent do\nend\n"
    hash = Script.hash(code)

    row =
      Repo.insert!(
        Script.changeset(%Script{}, %{
          name: name,
          code: code,
          code_hash: hash,
          accepted_hash: hash,
          accepted_at: DateTime.utc_now() |> DateTime.truncate(:second),
          origin: "authored",
          contract: YmerNode.Script.contract(),
          description: name,
          declarations: %{"hosts" => hosts, "url_action" => "fetch", "secrets" => []}
        })
      )

    on_exit(fn -> Repo.delete_all(from script in Script, where: script.id == ^row.id) end)
    row
  end
end
