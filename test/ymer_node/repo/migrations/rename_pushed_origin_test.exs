defmodule YmerNode.Repo.Migrations.RenamePushedOriginTest do
  @moduledoc """
  Runs the migration that renames the origin `pushed` through `Ecto.Migrator`,
  under the arrangement `YmerNode.Repo.Migrations.PlantExampleScriptTest`
  explains: a plain `ExUnit.Case`, `async: false`, the sandbox in `:auto` for
  the duration, the version unrecorded by `setup` and recorded again on exit,
  and the file loaded by hand on a run whose boot did not load it.

  Rows are written through the changeset as `authored` and then given their
  origin with `Repo.update_all/2`, because the changeset refuses `pushed` — the
  word the migration exists to retire. Every row a case writes is deleted by id
  on exit.
  """
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog

  alias Ecto.Adapters.SQL.Sandbox
  alias YmerNode.Repo
  alias YmerNode.Repo.Migrations.RenamePushedOrigin
  alias YmerNode.Scripts.Script

  @version 20_260_924_090_000
  @path Application.app_dir(
          :ymer_node,
          "priv/repo/migrations/20260924090000_rename_pushed_origin.exs"
        )

  setup do
    unless Code.ensure_loaded?(RenamePushedOrigin), do: Code.require_file(@path)

    # Registered before the sandbox mode moves, so a `setup` that fails after
    # it still puts the mode back and records the version again.
    on_exit(fn ->
      # With a later migration recorded, the migrator warns that an older one
      # is running; here that is the arrangement, not a hazard.
      capture_log(fn -> Ecto.Migrator.up(Repo, @version, RenamePushedOrigin, log: false) end)
      Sandbox.mode(Repo, :manual)
    end)

    Sandbox.mode(Repo, :auto)

    unrecorded = Ecto.Migrator.down(Repo, @version, RenamePushedOrigin, log: false)
    assert unrecorded in [:ok, :already_down]

    :ok
  end

  describe "change/0" do
    test "up rewrites every row of origin pushed to imported, and no other" do
      pushed = row!("pushed")
      authored = row!("authored")

      assert :ok = Ecto.Migrator.up(Repo, @version, RenamePushedOrigin, log: false)

      assert Repo.get!(Script, pushed.id).origin == "imported"
      assert Repo.get!(Script, authored.id).origin == "authored"
    end

    test "down writes pushed back over imported" do
      row = row!("pushed")
      assert :ok = Ecto.Migrator.up(Repo, @version, RenamePushedOrigin, log: false)

      assert :ok = Ecto.Migrator.down(Repo, @version, RenamePushedOrigin, log: false)

      assert Repo.get!(Script, row.id).origin == "pushed"
    end
  end

  defp row!(origin) do
    name = "renamed#{System.unique_integer([:positive])}"
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
          declarations: %{"hosts" => [], "url_action" => nil, "secrets" => []}
        })
      )

    on_exit(fn -> Repo.delete_all(from script in Script, where: script.id == ^row.id) end)
    Repo.update_all(from(script in Script, where: script.id == ^row.id), set: [origin: origin])
    row
  end
end
