defmodule YmerNode.Mcp.Tools.ScriptsTest do
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
  alias YmerNode.Mcp.Tools.Scripts

  describe "tool wiring" do
    test "passes framework validation and exposes the expected surface" do
      assert :ok = Actions.validate!(Scripts)

      assert %{"properties" => %{"action" => %{"enum" => [_ | _]}}} = Schema.build(Scripts)

      assert %{"type" => "object", "required" => ["action"]} = Scripts.input_schema()

      assert Scripts.name() == "scripts"
      assert Scripts.title() == "Scripts"
    end

    @tag doc: """
         The only open-world tool on this node, and the reason is `run`: a script
         reaches the network with the node's own permissions. A failure on the
         openWorldHint leg means someone read the tool as local-only — and a
         client that believes that will hand it a call whose effects it would not
         have authorised.
         """
    test "is annotated destructive and open-world" do
      assert Scripts.annotations() == %{
               "destructiveHint" => true,
               "openWorldHint" => true
             }
    end

    test "the description tells a worker to describe before it runs" do
      assert Scripts.description() =~ "Read describe before you run"
      assert Scripts.description() =~ "accepted at exactly the code it holds"
    end

    test "the description names info as the read before a promised package's first use" do
      assert Scripts.description() =~ "info renders a promised package's own docs"
    end
  end

  describe "handle_error/1" do
    test "renders both the bare reason and the reason-with-context shapes" do
      assert Scripts.handle_error({:not_found, "no script named hex"}) =~ "no script named hex"

      assert Scripts.handle_error({{:not_found, "no script named hex"}, %{action_verb: "run"}}) =~
               "no script named hex"
    end
  end
end
