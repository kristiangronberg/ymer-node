defmodule YmerNode.Mcp.Tools.ReferencesTest do
  @moduledoc """
  Pins the tool's wiring: that the framework accepts its action schemas, and
  that the surface a client meets is the one this repo means to serve.

  The validation call matters because nothing else in `mix test` makes it. The
  mount validates at its own compile, so a malformed schema that got past
  compilation would surface first as a failing request against a running node —
  and it would fail the whole `/mcp` endpoint, every tool on it, not only this
  one.
  """
  use ExUnit.Case, async: true

  alias Wymcp.Tool.Actions
  alias Wymcp.Tool.Schema
  alias YmerNode.Mcp.Tools.References

  describe "tool wiring" do
    test "passes framework validation and exposes the expected surface" do
      assert :ok = Actions.validate!(References)

      assert %{"properties" => %{"action" => %{"enum" => [_ | _]}}} = Schema.build(References)

      assert %{"type" => "object", "required" => ["action"]} = References.input_schema()

      assert References.name() == "references"
      assert References.title() == "References"
    end

    @tag doc: """
         Destructive because `remove` hard-deletes; closed-world because the tool
         reaches nothing but this node's own database. A failure on the
         openWorldHint leg means someone read "the results point outward" as "the
         tool fetches" — it does not, and a client that believes it does will
         stop calling the target's own tool.
         """
    test "is annotated destructive and closed-world" do
      assert References.annotations() == %{
               "destructiveHint" => true,
               "openWorldHint" => false
             }
    end
  end

  describe "handle_error/1" do
    test "renders both the bare reason and the reason-with-context shapes" do
      assert References.handle_error(:not_found) =~ "Reference not found"

      assert References.handle_error({:not_found, %{action_verb: "get reference"}}) =~
               "Reference not found"
    end
  end
end
