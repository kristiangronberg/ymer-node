defmodule YmerNode.Mcp.Tools.References.SchemasTest do
  @moduledoc """
  Pins the `references` tool's action-schema shape. No database and no
  framework calls, so `async: true`: every assertion here is a pure read of a
  module attribute.

  The tool module's own wiring — that the framework accepts these schemas — is
  pinned in `YmerNode.Mcp.Tools.ReferencesTest`, beside the module that
  declares them.
  """
  use ExUnit.Case, async: true

  alias YmerNode.Mcp.Tools.References.Schemas

  test "defines exactly the six actions" do
    assert Enum.sort(Map.keys(Schemas.all())) ==
             Enum.sort(~w(find add get update remove list)a)
  end

  test "required params per action" do
    all = Schemas.all()

    assert all.add.required == ["title", "uri"]
    assert all.get.required == ["id"]
    assert all.update.required == ["id"]
    assert all.remove.required == ["id"]
    assert all.find.required == []
    assert all.list.required == []
  end

  @tag doc: """
       The source property carries no `enum`, deliberately: the vocabulary is
       runtime data — three built-ins plus every accepted script's name — so a
       compile-time list would start lying the first time a script was accepted,
       and a caller filtering by a legitimate script name would be refused by the
       schema before the tool ever saw the call. A failure means an enum came
       back; the invalid-source error message is where the current vocabulary
       belongs.
       """
  test "the find schema's source property carries no enum and points at scripts" do
    source = Schemas.all().find.properties["source"]

    refute Map.has_key?(source, "enum")
    assert source["description"] =~ "accepted script"
  end

  test "every action's description is newline-free — the tools/list join constraint" do
    for {action, schema} <- Schemas.all() do
      refute String.contains?(schema.description, "\n"),
             "#{action}: action descriptions may not contain a newline"
    end
  end
end
