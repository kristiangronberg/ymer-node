defmodule YmerNode.Mcp.Tools.Notebook.ActionsTest do
  @moduledoc """
  The backup describe block overrides `config :ymer_node, YmerNode.Notebook.Backup`
  per test and restores it in `on_exit`, so those cases must not run async against
  anything else reading that key. Sandbox and async caveats come from
  `YmerNode.NotebookCase`.
  """
  use YmerNode.NotebookCase
  alias YmerNode.Mcp.Tools.Notebook.Actions
  alias YmerNode.Mcp.Tools.Notebook.Errors
  alias YmerNode.Mcp.Tools.Notebook.Schemas
  alias YmerNode.Notebook.Backup

  describe "run/2" do
    test "execute returns affected_rows and query returns columns/rows" do
      assert {:ok, %{affected_rows: 0}, _} =
               Actions.run(:execute, %{"sql" => "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)"})

      assert {:ok, %{affected_rows: 1}, _} =
               Actions.run(:execute, %{"sql" => "INSERT INTO t (v) VALUES ('a')"})

      assert {:ok, %{columns: ["id", "v"], rows: [[1, "a"]]}, _} =
               Actions.run(:query, %{"sql" => "SELECT id, v FROM t"})
    end

    test "query rejects a write with a helpful error tuple" do
      assert {:error, {:not_read_only, _ctx}} =
               Actions.run(:query, %{"sql" => "DELETE FROM sqlite_master"})
    end

    test "tables and schema reflect created tables" do
      {:ok, _, _} = Actions.run(:execute, %{"sql" => "CREATE TABLE t (id INTEGER PRIMARY KEY)"})
      assert {:ok, %{tables: tables}, _} = Actions.run(:tables, %{})
      assert Enum.any?(tables, &(&1.name == "t"))
      assert {:ok, %{table: "t", virtual: false}, _} = Actions.run(:schema, %{"table" => "t"})
    end

    @tag doc: """
         Covers the vector-search path through the MCP trust boundary too: a vec0 KNN SELECT
         issued via the query action returns columns (incl. the synthetic `distance`) and the
         nearest doc first. The full context-level round-trip lives in notebook_test.exs; this
         proves the tool layer carries it through unchanged. The KNN MATCH+LIMIT runs in its
         own CTE then joins by rowid (sqlite-vec won't push a LIMIT through a direct join).
         """
    test "a vec0 KNN search runs through the query action with the distance column" do
      {:ok, _, _} =
        Actions.run(:execute, %{"sql" => "CREATE TABLE docs (id INTEGER PRIMARY KEY, body TEXT)"})

      {:ok, _, _} =
        Actions.run(:execute, %{
          "sql" => "CREATE VIRTUAL TABLE vec_docs USING vec0(embedding float[3])"
        })

      {:ok, _, _} =
        Actions.run(:execute, %{
          "sql" => "INSERT INTO docs (id, body) VALUES (1, 'near'), (2, 'far')"
        })

      {:ok, _, _} =
        Actions.run(:execute, %{
          "sql" => "INSERT INTO vec_docs (rowid, embedding) VALUES (1, '[1,0,0]'), (2, '[0,1,0]')"
        })

      assert {:ok, %{columns: cols, rows: [["near", _] | _]}, _} =
               Actions.run(:query, %{
                 "sql" =>
                   "WITH knn AS (SELECT rowid, distance FROM vec_docs " <>
                     "WHERE embedding MATCH '[1,0,0]' ORDER BY distance LIMIT 2) " <>
                     "SELECT d.body, knn.distance FROM knn JOIN docs d ON d.id = knn.rowid ORDER BY knn.distance"
               })

      assert "distance" in cols
    end

    @tag doc: """
         The wrong-typed twin of every guarded head, read off the schema table
         rather than listed by hand: for each required parameter the table declares
         as a string, a present value holding a number, a boolean, a list, an object
         or `null` is refused with a reason the caller can act on, instead of
         matching no clause and reaching the MCP framework's fault containment as a
         `tool_fault` FunctionClauseError. Every other required parameter of the
         action rides along as a valid string, so an action with two required
         strings still meets its heads. The premise assertion trips first if a
         required parameter stops being a string — such a parameter needs a twin
         and a message of its own. A failure past it means a required string
         parameter gained a guarded head and no twin — the pre-twin crash, back
         for that one action — or a guarded head stopped guarding; find out which
         before relaxing the assertion, because only one of the two is a
         documentation problem.
         """
    test "a present parameter of the wrong type is refused, not raised" do
      required =
        for {action, %{properties: properties} = schema} <- Schemas.all(),
            key <-
              Map.get(schema, :required, []) ++
                List.flatten(Map.get(schema, :required_one_of, [])),
            do: {action, key, properties[key]["type"]}

      assert {:execute, "sql", "string"} in required
      assert Enum.all?(required, fn {_action, _key, type} -> type == "string" end)

      for {action, key, _type} <- required, value <- [42, true, [], %{}, nil] do
        siblings =
          for {^action, other, _type} <- required, other != key, into: %{}, do: {other, "ok"}

        assert {:error, {{:wrong_type, %{key: ^key, got: ^value}}, ctx}} =
                 Actions.run(action, Map.put(siblings, key, value))

        assert is_binary(ctx.action_verb)
      end

      assert {:error, {_reason, %{action_verb: "execute SQL"}}} =
               Actions.run(:execute, %{"sql" => 42})
    end
  end

  describe "run/2 — the folded-in backup actions" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "tool_backup_#{System.unique_integer([:positive])}")
      prev = Application.get_env(:ymer_node, Backup)
      Application.put_env(:ymer_node, Backup, directory: tmp, retain: 40)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:ymer_node, Backup, prev),
          else: Application.delete_env(:ymer_node, Backup)

        File.rm_rf!(tmp)
      end)

      %{tmp: tmp}
    end

    test "list returns the shaped listing", %{tmp: tmp} do
      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, "notebook-2026-08-30-12-00-00.db"), "xx")
      File.write!(Path.join(tmp, "notes.txt"), "not a backup")

      assert {:ok, %{count: 1, backups: [entry]}, _} = Actions.run(:list, %{})
      assert entry.id == "2026-08-30-12-00-00"
      assert entry.size_bytes == 2
    end

    test "restore maps a malformed id and an unknown id to error tuples" do
      assert {:error, {:invalid_backup_id, _ctx}} =
               Actions.run(:restore, %{"id" => "../../etc/passwd"})

      assert {:error, {:backup_not_found, _ctx}} =
               Actions.run(:restore, %{"id" => "2026-01-01-00-00-00"})
    end

    @tag :capture_log
    @tag doc: """
         Runtime no-leak at the boundary a worker actually reads. `File` bang
         operations embed absolute paths, and an uncaught raise would reach the MCP
         framework's own top-level rescue, which ships `Exception.message/1`
         verbatim into the caller's context. The failure is forced
         deterministically — `:directory` points *under* a regular file, so every
         filesystem operation raises ENOTDIR carrying the path. Asserting on the
         formatted message rather than the atom is the point: that string is what
         the caller sees. Keep the `reason in …` assertion ahead of it — without
         it the case is satisfied by the generic `message/2` catch-all, which is
         also leak-free, and the three backup-specific clauses go unexercised. A
         failure here means a rescue or a message clause was dropped and the
         boundary now leaks.
         """
    test "forced create/list/restore failures never leak a path to the caller" do
      blocker = Path.join(System.tmp_dir!(), "leak_#{System.unique_integer([:positive])}")
      File.write!(blocker, "x")
      bad_dir = Path.join(blocker, "backups")
      Application.put_env(:ymer_node, Backup, directory: bad_dir, retain: 40)
      on_exit(fn -> File.rm_rf!(blocker) end)

      cases = [{:create, %{}}, {:list, %{}}, {:restore, %{"id" => "2026-01-01-00-00-00"}}]

      for {action, args} <- cases do
        assert {:error, {reason, ctx}} = Actions.run(action, args)
        assert reason in [:backup_failed, :backups_failed, :restore_failed]
        msg = String.downcase(Errors.format(reason, ctx))

        for forbidden <-
              ["path", "file", "directory", ".db", "/data", "notebook-", String.downcase(bad_dir)] do
          refute msg =~ forbidden, "leaked #{inspect(forbidden)} to the caller: #{msg}"
        end
      end
    end
  end
end
