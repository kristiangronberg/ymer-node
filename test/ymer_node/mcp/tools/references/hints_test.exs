defmodule YmerNode.Mcp.Tools.References.HintsTest do
  use ExUnit.Case, async: true

  alias YmerNode.Mcp.Tools.References.Hints

  test "add and update steer at viewing the reference" do
    for action <- [:add, :update] do
      assert [hint] = Hints.for(action, %{id: 7})
      assert hint.tool == "references"
      assert hint.action == "get"
      assert hint.example == %{data: %{id: 7}}
    end
  end

  @tag doc: """
       The duplicate-add path carries the same hint, pointing at the reference
       that already exists — that steer is the whole reason the duplicate is
       answered as a success rather than an error. A failure means a caller told
       "this already exists as #N" is given no way to go and look at it.
       """
  test "the duplicate-add context still steers, at the existing reference" do
    assert [hint] = Hints.for(:add, %{id: 7, duplicate: true})
    assert hint.example == %{data: %{id: 7}}
  end

  test "read actions and unknown contexts emit no hints" do
    assert Hints.for(:find, %{}) == []
    assert Hints.for(:list, %{}) == []
    assert Hints.for(:get, %{id: 7}) == []
    assert Hints.for(:remove, %{}) == []
  end
end
