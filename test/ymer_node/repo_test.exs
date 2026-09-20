defmodule YmerNode.RepoTest do
  @moduledoc """
  Deleting the node database and restarting its repo is something a sandbox
  owner cannot survive, so this module uses a plain `ExUnit.Case`, is
  `async: false`, and puts both the repo and the sandbox mode back before the
  test ends.

  Two pieces of setup are not obvious and are both load-bearing.

  The sandbox is switched to `:auto` for the duration: under `:manual` a process
  owning no connection cannot check one out, and the migrator's own task raises
  `DBConnection.OwnershipError` before it reaches the first migration.

  The migrator is called directly rather than by restarting the `Ecto.Migrator`
  child. That child migrates inside `init/1` and returns `:ignore`, which leaves
  it supervised with no process: the supervisor keeps the child spec — a
  non-temporary child is retained on `:ignore` — so it is listed as
  `{Ecto.Migrator, :undefined}`. Under an `:auto` sandbox
  `Supervisor.restart_child/2` re-runs the migrations and answers
  `{:ok, :undefined}`, with no result to assert on; under the suite's `:manual`
  sandbox the migrator's own task cannot check out a connection, so the same
  restart answers `{:error, {%DBConnection.OwnershipError{}, _}}` before any
  migration runs. `Ecto.Migrator.run/4` is the same call the child makes and
  returns the versions it applied, so the test exercises the boot path rather
  than a stand-in.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias YmerNode.Repo

  @migrations Application.app_dir(:ymer_node, "priv/repo/migrations")

  describe "the node database" do
    @tag doc: """
         The rebuildable claim itself — the property on which the durability rule
         admits a second database at all: delete node.db and the next boot brings
         it back empty and current. A failure means the node database has quietly
         become something a backup would have to cover, so check whether
         migrations still run at boot before touching the rule's wording in
         `YmerNode`, the glossary, or the README.
         """
    test "comes back empty and current after its file is deleted" do
      database = Application.get_env(:ymer_node, Repo)[:database]

      Sandbox.mode(Repo, :auto)

      on_exit(fn ->
        Supervisor.restart_child(YmerNode.Supervisor, Repo)
        Ecto.Migrator.run(Repo, @migrations, :up, all: true)
        Sandbox.mode(Repo, :manual)
      end)

      :ok = Supervisor.terminate_child(YmerNode.Supervisor, Repo)
      Enum.each([database, database <> "-wal", database <> "-shm"], &File.rm/1)
      refute File.exists?(database)

      {:ok, _pid} = Supervisor.restart_child(YmerNode.Supervisor, Repo)

      # No File.exists? assertion belongs here: exqlite creates the file on its
      # first connection, and the restarted pool has not connected yet. The
      # migrator below is what brings the file back, which is exactly the boot
      # sequence this test stands for.
      assert [_ | _] = Ecto.Migrator.run(Repo, @migrations, :up, all: true)

      assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM reference_entries")

      # Every migration on disk, not a fixed count: this assertion is about the
      # rebuild being COMPLETE, and a number written here would go stale the
      # next time a table is added and read as a rebuild failure.
      applied =
        Repo.query!("SELECT version FROM schema_migrations ORDER BY version").rows
        |> Enum.map(&hd/1)

      on_disk =
        @migrations
        |> Path.join("*.exs")
        |> Path.wildcard()
        |> Enum.map(&(&1 |> Path.basename() |> String.split("_") |> hd() |> String.to_integer()))
        |> Enum.sort()

      assert on_disk != []
      assert applied == on_disk
    end
  end

  describe "ecto_repos" do
    @tag doc: """
         The one-entry list is what keeps `mix ecto.drop` away from the store:
         every repo listed there is one the mix tasks may drop, and the
         notebook's holds the one file the durability rule (`YmerNode`) exists
         for. A failure means a second repo was listed — almost certainly
         `YmerNode.Notebook.Repo`, copied in beside this one — and the next
         `mix ecto.drop` deletes `notebook.db` with no prompt. Take it back out:
         the notebook repo owns no schema, and no mix task may manage it.
         """
    test "lists the node database's repo and nothing else" do
      assert Application.get_env(:ymer_node, :ecto_repos) == [Repo]
    end
  end

  describe "the adapter's JSON codec" do
    @tag doc: """
         The `tags` column is JSON text, encoded through whichever module
         `:ecto_sqlite3`'s `:json_library` names, and that module must be one
         the release ships: the adapter's default, `Jason`, is no dependency of
         this project and reaches dev and test only through `mix_audit` and
         `credo`, so a green suite says nothing about the release. A failure
         means the pin was dropped or moved to a library outside Elixir's own
         standard library, and the first `references add` in a container raises
         `Ecto.ChangeError` on the tags dump.
         """
    test "encodes array columns through Elixir's own JSON module" do
      assert Application.get_env(:ecto_sqlite3, :json_library) == JSON

      assert {:ok, ~s(["a"])} =
               Ecto.Type.adapter_dump(Ecto.Adapters.SQLite3, {:array, :string}, ["a"])
    end
  end
end
