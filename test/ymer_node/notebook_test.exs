defmodule YmerNode.NotebookTest do
  use YmerNode.NotebookCase

  describe "execute/1" do
    test "runs DDL and returns affected_rows 0" do
      assert {:ok, %{affected_rows: 0}} =
               Notebook.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
    end

    test "INSERT returns the affected row count" do
      {:ok, _} = Notebook.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
      assert {:ok, %{affected_rows: 1}} = Notebook.execute("INSERT INTO t (v) VALUES ('a')")
    end

    @tag doc: """
         Failure means run_write/write_count regressed to trusting exqlite's num_rows.
         """
    test "lowercase DML reports the true affected_rows" do
      {:ok, _} = Notebook.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
      {:ok, _} = Notebook.execute("INSERT INTO t (v) VALUES ('a'), ('b'), ('c')")

      assert {:ok, %{affected_rows: 1}} = Notebook.execute("insert into t (v) values ('d')")
      assert {:ok, %{affected_rows: 4}} = Notebook.execute("update t set v = 'z'")
      assert {:ok, %{affected_rows: 4}} = Notebook.execute("delete from t")
    end

    test "DDL containing a DELETE/UPDATE substring still reports affected_rows 0" do
      {:ok, _} = Notebook.execute("CREATE TABLE parent (id INTEGER PRIMARY KEY)")
      {:ok, _} = Notebook.execute("INSERT INTO parent (id) VALUES (1), (2)")

      assert {:ok, %{affected_rows: 0}} =
               Notebook.execute("CREATE TABLE DELETED_ITEMS (id INTEGER PRIMARY KEY)")

      assert {:ok, %{affected_rows: 0}} =
               Notebook.execute(
                 "CREATE TABLE child (id INTEGER PRIMARY KEY, p INTEGER REFERENCES parent (id) ON DELETE CASCADE)"
               )
    end

    test "auto-creates _meta on first call" do
      {:ok, _} = Notebook.execute("CREATE TABLE t (id INTEGER PRIMARY KEY)")

      assert {:ok, %{rows: [[1]]}} =
               Notebook.query("SELECT count(*) FROM sqlite_master WHERE name = '_meta'")
    end

    @tag doc: """
         The `;ATTACH` and inline-comment cases were the live holes this test closed.
         The `PRAGMA database_list` check is not redundant with the per-attack
         `{:error, :blocked_statement}` assertions — never drop it as duplicate
         coverage.
         """
    test "blocks ATTACH behind a comment, semicolon, paren, or inline comment" do
      attacks = [
        "/* sneaky */ ATTACH DATABASE '/tmp/x.db' AS x",
        "-- sneaky\nATTACH DATABASE '/tmp/x.db' AS x",
        "/* a *//* b */ ATTACH DATABASE '/tmp/x.db' AS x",
        ";ATTACH DATABASE '/tmp/x.db' AS x",
        "(ATTACH DATABASE '/tmp/x.db' AS x)",
        "ATTACH/**/DATABASE '/tmp/x.db' AS x"
      ]

      for sql <- attacks do
        assert {:error, :blocked_statement} = Notebook.execute(sql)
      end

      # Backstop (run the PRAGMA directly — query/1 rejects PRAGMA): nothing attached.
      {:ok, %{rows: rows}} = Repo.query("PRAGMA database_list")
      assert Enum.map(rows, fn [_seq, name | _] -> name end) == ["main"]
    end

    @tag doc: """
         An unterminated `/*` makes SQLite treat the rest of the statement as a comment to
         EOF — so `/* ATTACH …` is an inert no-op, NOT a guard rejection. Assert no attach
         happened rather than asserting :blocked_statement (the classifier sees an empty lead).
         """
    test "an unterminated block comment hiding ATTACH is an inert no-op" do
      assert {:ok, _} = Notebook.execute("/* ATTACH DATABASE '/tmp/x.db' AS x")
      {:ok, %{rows: rows}} = Repo.query("PRAGMA database_list")
      assert Enum.map(rows, fn [_seq, name | _] -> name end) == ["main"]
    end

    @tag doc: """
         Guards the regression where `strip_comments/1` ran its block-comment rules
         before its line-comment rule: an unpaired `/*` inside a leading `--` comment
         let the to-EOF rule swallow the statement after it, so the write never ran
         and `execute/1` still answered `{:ok, %{affected_rows: 0}}`. A failure means
         the single left-to-right alternation was split back into ordered passes —
         silent data loss in the one store this node promises to keep.
         """
    test "a write behind a line comment containing an unpaired /* still runs" do
      assert {:ok, _} = Notebook.execute("CREATE TABLE c (id INTEGER PRIMARY KEY, v TEXT)")

      assert {:ok, %{affected_rows: 1}} =
               Notebook.execute("-- see notes/*.sql\nINSERT INTO c (v) VALUES ('kept')")

      assert {:ok, %{rows: [["kept"]]}} = Notebook.query("SELECT v FROM c")
    end

    test "surfaces SQLite errors verbatim" do
      assert {:error, %Exqlite.Error{}} = Notebook.execute("CREATE TABLE")
    end

    @tag doc: """
         Bare VACUUM must NOT be classified as blocked: under the sandbox it
         reaches SQLite and fails there (VACUUM cannot run inside a transaction),
         which is the proof it was attempted rather than refused at the
         classifier. A failure on the blocked assertions means the INTO
         discriminator loosened; on the bare-VACUUM one, that it over-tightened.
         """
    test "blocks VACUUM INTO in any spelling but lets bare VACUUM through" do
      attacks = [
        "VACUUM INTO '/tmp/x.db'",
        "vacuum/**/into '/tmp/x.db'",
        "VACUUM main INTO '/tmp/x.db'",
        ";vacuum into '/tmp/x.db'"
      ]

      for sql <- attacks do
        assert {:error, :blocked_vacuum_into} = Notebook.execute(sql)
      end

      assert {:error, %Exqlite.Error{message: message}} = Notebook.execute("VACUUM")
      assert message =~ "transaction"
    end
  end

  describe "query/1" do
    setup do
      {:ok, _} = Notebook.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
      {:ok, _} = Notebook.execute("INSERT INTO t (v) VALUES ('a'), ('b')")
      :ok
    end

    test "returns columns and rows" do
      assert {:ok, %{columns: ["id", "v"], rows: [[1, "a"], [2, "b"]]}} =
               Notebook.query("SELECT id, v FROM t ORDER BY id")
    end

    @tag doc: """
         These inputs FAIL exqlite's command heuristic (uppercase substrings); a
         regression returns rows with columns == []. Lowercase substrings don't trigger
         the bug, so these are deliberately uppercase.
         """
    test "recovers columns for SELECTs containing an uppercase DML substring" do
      assert {:ok, %{columns: ["id", "v"], rows: []}} =
               Notebook.query("SELECT id, v FROM t WHERE v = 'DELETED'")

      assert {:ok, %{columns: ["id", "v"]}} =
               Notebook.query("SELECT id, v FROM t WHERE v LIKE '%UPDATE%'")

      assert {:ok, %{columns: ["label"], rows: [["INSERTED"]]}} =
               Notebook.query("SELECT 'INSERTED' AS label")
    end

    test "rejects a non-SELECT/WITH statement" do
      assert {:error, :not_read_only} = Notebook.query("INSERT INTO t (v) VALUES ('c')")
    end

    test "accepts EXPLAIN reads but rejects PRAGMA" do
      assert {:ok, %{rows: [_ | _]}} = Notebook.query("EXPLAIN QUERY PLAN SELECT * FROM t")
      assert {:error, :not_read_only} = Notebook.query("PRAGMA table_info(t)")
    end

    @tag doc: """
         A statement beginning with `(` once tokenised to an empty leading word and was
         wrongly rejected as :not_read_only. SQLite has no valid top-level `(`-led
         statement (verified: both `(SELECT 1)` and `(SELECT 1) UNION (SELECT 2)` are
         syntax errors), so the proof that it routed — not rejected — is a SQLite
         syntax error rather than our `:not_read_only`. The security-relevant
         `(`-stripping (`(ATTACH …)` → blocked) is covered by the execute ATTACH
         attack test.
         """
    test "routes a leading-paren statement by its inner keyword; compound reads return rows" do
      assert {:error, %Exqlite.Error{}} = Notebook.query("(SELECT 1) UNION (SELECT 2)")

      assert {:ok, %{rows: rows}} = Notebook.query("SELECT 1 UNION SELECT 2")
      assert Enum.sort(rows) == [[1], [2]]
    end

    test "accepts a SELECT behind a leading comment" do
      assert {:ok, %{columns: ["id", "v"]}} = Notebook.query("/* c */ SELECT id, v FROM t")
    end

    @tag doc: """
         Two independent guarantees, one test: the guard rejects the statement, and
         nothing persists. The second is what `query/1`'s always-rollback buys (the
         module's "Read-only enforcement" section), not what the guard buys — so do
         not drop the count check as implied by the `:not_read_only` assertion above
         it. The CTE-led DELETE below pins that same persistence guarantee for a
         write the guard does let through.
         """
    test "a commented DELETE neither runs as a read nor persists" do
      assert {:error, :not_read_only} = Notebook.query("/* c */ DELETE FROM t")
      assert {:ok, %{rows: [[2]]}} = Notebook.query("SELECT count(*) FROM t")
    end

    test "a CTE-led DELETE is rolled back (no persistence)" do
      assert {:ok, _} = Notebook.query("WITH x AS (SELECT 1) DELETE FROM t")
      assert {:ok, %{rows: [[2]]}} = Notebook.query("SELECT count(*) FROM t")
    end

    test "load_extension() is not authorized on the read path" do
      assert {:error, %Exqlite.Error{}} =
               Notebook.query("SELECT load_extension('/tmp/whatever')")
    end
  end

  describe "cold start" do
    @tag doc: """
         This block has NO table-creating setup, so it exercises the genuine cold
         path: the persistence check pins that `_meta` survives a read, which
         `ensure_meta!/0` running BEFORE `run_read_only/1`'s always-rollback
         transaction provides. A failure means that ordering changed — look there
         before touching the test.
         """
    test "a first-ever query auto-creates and persists _meta despite the rollback" do
      assert {:ok, %{rows: [[1]]}} = Notebook.query("SELECT 1")

      assert {:ok, %{rows: [[1]]}} =
               Notebook.query("SELECT count(*) FROM sqlite_master WHERE name = '_meta'")
    end
  end

  describe "tables/0" do
    @tag doc: """
         Guards the cold path no other test exercises — every other tables/0 case
         creates tables in setup first.
         """
    test "returns [] on a fresh database (no user tables yet)" do
      assert Notebook.tables() == []
    end

    test "lists user tables with row counts and descriptions, hides _meta and shadow tables" do
      {:ok, _} = Notebook.execute("CREATE TABLE docs (id INTEGER PRIMARY KEY, body TEXT)")
      {:ok, _} = Notebook.execute("INSERT INTO docs (body) VALUES ('x'), ('y')")
      {:ok, _} = Notebook.execute("CREATE VIRTUAL TABLE vec_docs USING vec0(embedding float[4])")

      {:ok, _} =
        Notebook.execute(
          "INSERT OR REPLACE INTO _meta (target, description) VALUES ('table:docs', 'Indexed docs')"
        )

      tables = Notebook.tables()
      docs = Enum.find(tables, &(&1.name == "docs"))
      vec = Enum.find(tables, &(&1.name == "vec_docs"))

      assert docs == %{name: "docs", virtual: false, row_count: 2, description: "Indexed docs"}
      assert %{name: "vec_docs", virtual: true, row_count: nil} = vec
      refute Enum.any?(tables, &(&1.name == "_meta"))
      refute Enum.any?(tables, &String.starts_with?(&1.name, "vec_docs_"))
    end
  end

  describe "table_schema/1" do
    test "returns columns, pk, indexes and _meta descriptions for a regular table" do
      {:ok, _} =
        Notebook.execute("CREATE TABLE docs (id INTEGER PRIMARY KEY, body TEXT NOT NULL)")

      {:ok, _} = Notebook.execute("CREATE INDEX docs_body ON docs (body)")

      {:ok, _} =
        Notebook.execute(
          "INSERT OR REPLACE INTO _meta (target, description) VALUES ('column:docs.body', 'Raw text')"
        )

      assert {:ok, schema} = Notebook.table_schema("docs")
      assert schema.virtual == false
      id = Enum.find(schema.columns, &(&1.name == "id"))
      body = Enum.find(schema.columns, &(&1.name == "body"))
      # SQLite's PRAGMA table_info reports notnull=0 for an INTEGER PRIMARY KEY (the
      # rowid alias) unless NOT NULL is written explicitly — so id is pk:true,
      # not_null:false. The body column (declared NOT NULL) proves not_null detection.
      assert %{pk: true, not_null: false} = id
      assert %{not_null: true, description: "Raw text"} = body
      assert Enum.any?(schema.indexes, &(&1.name == "docs_body"))
    end

    test "parses vector column + dimension from the DDL for a vec0 table" do
      {:ok, _} =
        Notebook.execute("CREATE VIRTUAL TABLE vec_docs USING vec0(embedding float[768])")

      assert {:ok, schema} = Notebook.table_schema("vec_docs")
      assert schema.virtual == true
      assert [%{name: "embedding", type: "float[768]"}] = schema.columns
      assert schema.indexes == []
    end

    test "returns :table_not_found for an unknown table" do
      assert {:error, :table_not_found} = Notebook.table_schema("nope")
    end
  end

  describe "vector search (vec0 KNN round-trip)" do
    # vec0 is loaded into the sandbox connection by YmerNode.Notebook.Repo.init/2, so
    # this exercises the headline feature end-to-end with no network of any kind.
    # A 3-d embedding keeps distances hand-checkable. Writes go through execute (query
    # always rolls back); the KNN search goes through query (the always-rollback path).
    setup do
      {:ok, _} =
        Notebook.execute(
          "CREATE TABLE docs (id INTEGER PRIMARY KEY, page_key TEXT UNIQUE, body TEXT)"
        )

      {:ok, _} = Notebook.execute("CREATE VIRTUAL TABLE vec_docs USING vec0(embedding float[3])")

      {:ok, _} =
        Notebook.execute(
          "INSERT INTO docs (id, page_key, body) VALUES (1, 'NEAR', 'near'), (2, 'FAR', 'far')"
        )

      {:ok, _} =
        Notebook.execute(
          "INSERT INTO vec_docs (rowid, embedding) VALUES (1, '[1,0,0]'), (2, '[0,1,0]')"
        )

      :ok
    end

    test "KNN MATCH returns the distance column, nearest-first, out of the rollback" do
      assert {:ok, %{columns: cols, rows: [["near", d1], ["far", d2]]}} =
               Notebook.query(
                 "WITH knn AS (SELECT rowid, distance FROM vec_docs " <>
                   "WHERE embedding MATCH '[1,0,0]' ORDER BY distance LIMIT 2) " <>
                   "SELECT d.body, knn.distance FROM knn JOIN docs d ON d.id = knn.rowid ORDER BY knn.distance"
               )

      assert "distance" in cols
      assert d1 < d2
    end

    test "the rolled-back KNN read does not mutate the vec0 table" do
      {:ok, _} =
        Notebook.query(
          "SELECT v.distance FROM vec_docs v WHERE v.embedding MATCH '[1,0,0]' ORDER BY v.distance LIMIT 1"
        )

      assert {:ok, %{rows: [[2]]}} = Notebook.query("SELECT count(*) FROM vec_docs")
    end

    @tag doc: """
         Pinned at the vendored sqlite-vec v0.1.9 so a version bump that changes the
         behaviour is caught here rather than as a confusing runtime failure for the
         agent.
         """
    test "an unbounded MATCH (no LIMIT) errors" do
      assert {:error, %Exqlite.Error{}} =
               Notebook.query(
                 "SELECT v.distance FROM vec_docs v WHERE v.embedding MATCH '[1,0,0]'"
               )
    end

    test "deleting from both tables shrinks the KNN result set (no cascade)" do
      {:ok, _} = Notebook.execute("DELETE FROM docs WHERE id = 2")
      {:ok, _} = Notebook.execute("DELETE FROM vec_docs WHERE rowid = 2")

      assert {:ok, %{rows: [["near", _]]}} =
               Notebook.query(
                 "WITH knn AS (SELECT rowid, distance FROM vec_docs " <>
                   "WHERE embedding MATCH '[1,0,0]' ORDER BY distance LIMIT 5) " <>
                   "SELECT d.body, knn.distance FROM knn JOIN docs d ON d.id = knn.rowid ORDER BY knn.distance"
               )
    end
  end
end
