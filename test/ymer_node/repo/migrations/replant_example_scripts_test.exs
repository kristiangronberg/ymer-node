defmodule YmerNode.Repo.Migrations.ReplantExampleScriptsTest do
  @moduledoc """
  Runs the migration that brings the shipped examples forward through
  `Ecto.Migrator`, under the arrangement
  `YmerNode.Repo.Migrations.PlantExampleScriptTest` explains for its own
  migration: a plain `ExUnit.Case`, `async: false`, the sandbox in `:auto` for
  the duration, the version unrecorded by `setup` and recorded again on exit
  with the planting off, and every row a case inserted deleted by id.

  Each example an earlier build shipped is a fixture under
  `test/fixtures/replant_example_scripts`, byte for byte as that build shipped
  it, so the hashes the migration names are checked against the bytes they
  stand for. A fixture is never reformatted or edited: its hash is the point.
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias YmerNode.Repo
  alias YmerNode.Repo.Migrations.ReplantExampleScripts
  alias YmerNode.Scripts
  alias YmerNode.Scripts.Compiler
  alias YmerNode.Scripts.Script

  @version 20_261_113_120_000
  @path Application.app_dir(
          :ymer_node,
          "priv/repo/migrations/20261113120000_replant_example_scripts.exs"
        )
  @fixtures Path.expand("../../../fixtures/replant_example_scripts", __DIR__)
  @earlier [
    {"hex.exs", "hex_1.txt"},
    {"hex.exs", "hex_2.txt"},
    {"webpage.exs", "webpage_1.txt"}
  ]

  setup do
    unless Code.ensure_loaded?(ReplantExampleScripts), do: Code.require_file(@path)

    config = Application.get_env(:ymer_node, Scripts, [])

    on_exit(fn ->
      Ecto.Migrator.down(Repo, @version, ReplantExampleScripts, log: false)
      Application.put_env(:ymer_node, Scripts, config)
      capture_log(fn -> Ecto.Migrator.up(Repo, @version, ReplantExampleScripts, log: false) end)
      Compiler.purge(Module.concat(["Script", "Hex"]))
      Compiler.purge(Module.concat(["Script", "Webpage"]))
      Sandbox.mode(Repo, :manual)
    end)

    Sandbox.mode(Repo, :auto)
    Application.put_env(:ymer_node, Scripts, Keyword.put(config, :plant_example, true))

    unrecorded = Ecto.Migrator.down(Repo, @version, ReplantExampleScripts, log: false)
    assert unrecorded in [:ok, :already_down]

    :ok
  end

  describe "up/0" do
    test "brings a row at each earlier build's bytes to this build's, the row kept" do
      for {file, fixture} <- @earlier do
        row = insert_row!(file, fixture!(fixture), "shipped")

        # Deleted whatever the assertions do: a row left behind fails the later
        # cases and runs on this partition.
        try do
          assert :ok = Ecto.Migrator.up(Repo, @version, ReplantExampleScripts, log: false)

          replanted = Repo.get!(Script, row.id)
          assert replanted.code == File.read!(Scripts.example_path(file))
          assert replanted.version == "1.0.0"
          assert replanted.origin == "shipped"
          assert Script.accepted?(replanted)

          assert :ok = Ecto.Migrator.down(Repo, @version, ReplantExampleScripts, log: false)
        after
          Repo.delete_all(from script in Script, where: script.id == ^row.id)
        end
      end
    end

    test "leaves an example the operator edited or imported as it is" do
      edited = insert_row!("hex.exs", fixture!("hex_2.txt") <> "# edited\n", "shipped")
      imported = insert_row!("webpage.exs", fixture!("webpage_1.txt"), "imported")

      try do
        assert :ok = Ecto.Migrator.up(Repo, @version, ReplantExampleScripts, log: false)

        assert Repo.get!(Script, edited.id).code == edited.code
        assert Repo.get!(Script, imported.id).code == imported.code
      after
        Repo.delete!(edited)
        Repo.delete!(imported)
      end
    end

    test "changes nothing where the configuration turns the planting off" do
      config = Application.get_env(:ymer_node, Scripts, [])
      Application.put_env(:ymer_node, Scripts, Keyword.put(config, :plant_example, false))
      row = insert_row!("hex.exs", fixture!("hex_1.txt"), "shipped")

      try do
        assert :ok = Ecto.Migrator.up(Repo, @version, ReplantExampleScripts, log: false)
        assert Repo.get!(Script, row.id).code == row.code
      after
        Repo.delete!(row)
      end
    end
  end

  defp fixture!(fixture), do: File.read!(Path.join(@fixtures, fixture))

  defp insert_row!(file, code, origin) do
    name = Path.rootname(file)

    Repo.insert!(%Script{
      name: name,
      kind: "script",
      code: code,
      code_hash: Script.hash(code),
      accepted_hash: Script.hash(code),
      accepted_at: DateTime.utc_now() |> DateTime.truncate(:second),
      origin: origin,
      contract: 1,
      version: nil,
      description: name,
      declarations: %{}
    })
  end
end
