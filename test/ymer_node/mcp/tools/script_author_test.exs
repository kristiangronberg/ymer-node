defmodule YmerNode.Mcp.Tools.ScriptAuthorTest do
  @moduledoc """
  Pins the tool's wiring: that the framework accepts its action schemas, and
  that the surface a client meets is the one this repo means to serve.

  The validation call matters because nothing else in `mix test` makes it — see
  `YmerNode.Mcp.Tools.ScriptsTest` for what a malformed schema costs.
  """
  use ExUnit.Case, async: true

  alias Wymcp.Tool.Actions
  alias Wymcp.Tool.Schema
  alias YmerNode.Mcp.Tools.ScriptAuthor

  describe "tool wiring" do
    test "passes framework validation and exposes the expected surface" do
      assert :ok = Actions.validate!(ScriptAuthor)

      assert %{"properties" => %{"action" => %{"enum" => [_ | _]}}} = Schema.build(ScriptAuthor)

      assert %{"type" => "object", "required" => ["action"]} = ScriptAuthor.input_schema()

      assert ScriptAuthor.name() == "script_author"
      assert ScriptAuthor.title() == "Script Author"
    end

    @tag doc: """
         Destructive, and closed-world — the opposite of its sibling on the
         second leg. This tool compiles code and writes rows; it never runs an
         action, so nothing here reaches past this machine. A failure on the
         openWorldHint leg means the two tools' marks have been made the same,
         and the distinction the split exists for is gone from the wire.
         """
    test "is annotated destructive and closed-world" do
      assert ScriptAuthor.annotations() == %{
               "destructiveHint" => true,
               "openWorldHint" => false
             }
    end

    @tag doc: """
         The description carries the *Needs approval* recommendation, addressed
         to the human setting this tool's permission — the only text the node
         can put in front of them at that moment. If a client turns
         out not to render it there, the README's `Running it` carries the same
         recommendation; this assertion is what keeps the node's half of that
         arrangement from being edited away.
         """
    test "the description recommends approval, in a person's words" do
      description = ScriptAuthor.description()

      assert description =~ "Needs approval"
      assert description =~ "set it to ask"
      assert description =~ "what code this machine will run"
    end
  end

  describe "handle_error/1" do
    test "renders both the bare reason and the reason-with-context shapes" do
      assert ScriptAuthor.handle_error({:missing_contract, "no use line"}) =~
               "Add `use YmerNode.Script`"

      assert ScriptAuthor.handle_error(
               {{:missing_contract, "no use line"}, %{action_verb: "create a script"}}
             ) =~ "Add `use YmerNode.Script`"
    end
  end
end
