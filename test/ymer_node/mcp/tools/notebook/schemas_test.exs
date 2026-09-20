defmodule YmerNode.Mcp.Tools.Notebook.SchemasTest do
  @moduledoc """
  Tests the `notebook` action-schema map: every dispatched action has a schema with
  the right required fields, the map is well-formed for the MCP framework's
  boot-time validator, and the vector-usage guidance plus the KNN example carry
  their load-bearing tokens. Those `:notes`/`:examples` strings have a history of
  subtle drift — a failing test means the `help` output is telling LLM callers the
  wrong thing.
  """
  use ExUnit.Case, async: true

  alias Wymcp.Tool.Actions
  alias Wymcp.Tool.Schema
  alias YmerNode.Mcp.Tools.Notebook
  alias YmerNode.Mcp.Tools.Notebook.Schemas

  test "declares a schema for every dispatched action" do
    assert Enum.sort(Map.keys(Schemas.all())) ==
             ~w(create execute list query restore schema tables)a
  end

  test "required fields match the actions that need them" do
    all = Schemas.all()
    assert all.execute.required == ["sql"]
    assert all.query.required == ["sql"]
    assert all.schema.required == ["table"]
    assert all.tables.required == []
    assert all.create.required == []
    assert all.list.required == []
    assert all.restore.required == ["id"]
  end

  @tag doc: """
       @vec_notes is the single most load-bearing agent-facing string in the tool (the
       INTEGER-PRIMARY-KEY/rowid/LIMIT vec0 discipline). Pin its load-bearing tokens so a
       reword cannot silently drop the guidance that prevents corrupt KNN joins.
       """
  test "execute/query notes carry the vec0 INTEGER-PK discipline" do
    all = Schemas.all()

    for notes <- [all.execute.notes, all.query.notes] do
      assert notes =~ "INTEGER PRIMARY KEY"
      assert notes =~ "rowid"
      assert notes =~ "LIMIT"
    end
  end

  @tag doc: """
       The shipped KNN example is what an LLM copies verbatim; the executed round-trip lives
       in notebook_test.exs. Assert the example carries the same load-bearing tokens the test
       relies on — including the CTE shape (`WITH … knn.rowid`) that sqlite-vec v0.1.6
       requires (a direct join won't push the LIMIT down) — so guidance and tested pattern
       cannot silently diverge (it has a '...' placeholder, so it is asserted structurally,
       not executed).
       """
  test "the query KNN example carries the tokens the round-trip test pins" do
    sql = hd(Schemas.all().query.examples).data.sql

    for token <- ["WITH", "MATCH", "distance", "knn.rowid", "ORDER BY", "LIMIT"] do
      assert sql =~ token
    end
  end

  describe "tool wiring" do
    test "the Notebook tool passes the framework's boot-time validation" do
      # Exactly what Wymcp.Router.init/1 runs at boot over each registered tool.
      assert :ok = Actions.validate!(Notebook)

      assert %{"properties" => %{"action" => %{"enum" => [_ | _]}}} = Schema.build(Notebook)

      assert Notebook.name() == "notebook"
    end

    test "the tool description carries the pointer to the usage guide" do
      assert Notebook.description() =~ ~s|Call help {tool: "notebook"}|
    end
  end
end
