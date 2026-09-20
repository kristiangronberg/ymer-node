defmodule YmerNode.Mcp.Tools.Notebook.HintsTest do
  @moduledoc """
  The hint routing is asserted inline rather than through a fixture because it
  is small enough to read at a glance.
  """
  use ExUnit.Case, async: true

  alias YmerNode.Mcp.Tools.Notebook.Hints

  test "execute suggests confirming via tables, then reading the data back via query" do
    assert [tables_hint, query_hint] = Hints.for(:execute, %{})
    assert tables_hint.tool == "notebook" and tables_hint.action == "tables"
    assert query_hint.tool == "notebook" and query_hint.action == "query"
  end

  test "create suggests confirming the capture via list" do
    assert [list_hint] = Hints.for(:create, %{})
    assert list_hint.tool == "notebook" and list_hint.action == "list"
  end

  test "every other action returns no follow-up hints" do
    for action <- [:query, :tables, :schema, :list, :restore] do
      assert Hints.for(action, %{}) == []
    end
  end

  test "a restore that failed partway suggests restoring the safety backup" do
    assert [hint] = Hints.for(:restore, %{action: :restore, recover: "2026-08-30-12-00-00"})
    assert hint.tool == "notebook" and hint.action == "restore"
    assert hint.example == %{data: %{id: "2026-08-30-12-00-00"}}
  end

  test "a restore that never started suggests retrying it with the same id" do
    assert [hint] = Hints.for(:restore, %{action: :restore, retry: "2026-08-30-12-00-00"})
    assert hint.tool == "notebook" and hint.action == "restore"
    assert hint.example == %{data: %{id: "2026-08-30-12-00-00"}}
  end
end
