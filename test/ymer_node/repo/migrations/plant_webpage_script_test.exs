defmodule YmerNode.Repo.Migrations.PlantWebpageScriptTest do
  @moduledoc """
  Runs the migration that plants the `webpage` example script through
  `Ecto.Migrator`, the way the boot runs it, under the arrangement
  `YmerNode.Repo.Migrations.PlantExampleScriptTest` explains for its own
  migration: a plain `ExUnit.Case`, `async: false`, the sandbox in `:auto` for
  the duration, the version unrecorded by `setup` and recorded again on exit
  with the planting off, and every row a case inserted deleted by id.
  """
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias YmerNode.Repo
  alias YmerNode.Repo.Migrations.PlantWebpageScript
  alias YmerNode.Scripts
  alias YmerNode.Scripts.Compiler
  alias YmerNode.Scripts.Script

  @version 20_260_929_120_000
  @path Application.app_dir(
          :ymer_node,
          "priv/repo/migrations/20260929120000_plant_webpage_script.exs"
        )

  setup do
    unless Code.ensure_loaded?(PlantWebpageScript), do: Code.require_file(@path)

    config = Application.get_env(:ymer_node, Scripts, [])

    on_exit(fn ->
      Ecto.Migrator.down(Repo, @version, PlantWebpageScript, log: false)
      Application.put_env(:ymer_node, Scripts, config)
      capture_log(fn -> Ecto.Migrator.up(Repo, @version, PlantWebpageScript, log: false) end)
      Compiler.purge(Module.concat(["Script", "Webpage"]))
      Sandbox.mode(Repo, :manual)
    end)

    Sandbox.mode(Repo, :auto)
    Application.put_env(:ymer_node, Scripts, Keyword.put(config, :plant_example, true))

    unrecorded = Ecto.Migrator.down(Repo, @version, PlantWebpageScript, log: false)
    assert unrecorded in [:ok, :already_down]

    :ok
  end

  describe "up/0" do
    test "plants webpage as the accepted web fallback, of origin shipped" do
      assert :ok = Ecto.Migrator.up(Repo, @version, PlantWebpageScript, log: false)

      assert %Script{origin: "shipped"} = planted = Repo.get_by(Script, name: "webpage")
      assert Script.accepted?(planted)
      assert planted.code == File.read!(Scripts.example_path("webpage.exs"))
      assert %{"web_fallback" => true, "hosts" => [], "cache" => "text"} = planted.declarations
    end

    test "plants nothing where the configuration turns the planting off" do
      Application.put_env(:ymer_node, Scripts, plant_example: false)

      assert :ok = Ecto.Migrator.up(Repo, @version, PlantWebpageScript, log: false)
      assert Repo.get_by(Script, name: "webpage") == nil
    end

    @tag doc: """
         The migration reads the fallback refusal ahead of its raise clause, and
         the two have one shape. A failure that raises means the clauses were
         reordered, and an install whose operator already runs a web fallback
         dies at every boot; one that plants means the fallback rule left the
         build's door.
         """
    test "plants nothing, and logs why, where an accepted script is already the web fallback" do
      fallback = accepted_row!(%{"web_fallback" => true})

      log =
        capture_log(fn ->
          assert :ok = Ecto.Migrator.up(Repo, @version, PlantWebpageScript, log: false)
        end)

      assert log =~ "the webpage example script was not planted"
      assert log =~ "the accepted script #{fallback.name} is already the web fallback"
      assert Repo.get_by(Script, name: "webpage") == nil
    end
  end

  describe "down/0" do
    test "removes the row up planted, and no other shipped script" do
      other = accepted_row!(%{}, "shipped")
      assert :ok = Ecto.Migrator.up(Repo, @version, PlantWebpageScript, log: false)

      assert :ok = Ecto.Migrator.down(Repo, @version, PlantWebpageScript, log: false)

      assert Repo.get_by(Script, name: "webpage") == nil
      assert Repo.get!(Script, other.id).origin == "shipped"
    end
  end

  # An accepted row as the references seam reads it — no compile, no loader.
  defp accepted_row!(declared, origin \\ "authored") do
    name = "claimant#{System.unique_integer([:positive])}"
    code = "defmodule Script.Absent do\nend\n"
    hash = Script.hash(code)

    declarations =
      Map.merge(%{"hosts" => [], "url_action" => "fetch", "secrets" => []}, declared)

    row =
      Repo.insert!(
        Script.changeset(%Script{}, %{
          name: name,
          code: code,
          code_hash: hash,
          accepted_hash: hash,
          accepted_at: DateTime.utc_now() |> DateTime.truncate(:second),
          origin: origin,
          contract: YmerNode.Script.contract(),
          description: name,
          declarations: declarations
        })
      )

    on_exit(fn -> Repo.delete_all(from script in Script, where: script.id == ^row.id) end)
    row
  end
end
