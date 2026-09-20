defmodule YmerNode.Mcp.Tools.ScriptAuthor.HintsTest do
  use ExUnit.Case, async: true

  alias YmerNode.Mcp.Tools.ScriptAuthor.Hints

  @tag doc: """
       The write verbs steer at the OTHER tool, `scripts describe`. That is
       deliberate: what a caller wants after storing a script is to run it, and
       running lives next door. A client granted only `script_author` cannot
       follow the hint — which is the two-tool split working, not a bug.
       """
  test "create, update and accept steer at describing the script on the scripts tool" do
    for action <- [:create, :update, :accept] do
      assert [hint] = Hints.for(action, %{script: "hex"})
      assert hint.tool == "scripts"
      assert hint.action == "describe"
      assert hint.example == %{data: %{script: "hex"}}
    end
  end

  @tag doc: """
       No example on the check hint, deliberately. The caller holds the code it
       just sent, and an example carrying it back doubled the answer to the one
       call in this tool whose input is long. A `code` reappearing here means
       every check response has started echoing its whole input again.
       """
  test "check steers at storing the code it just checked, without echoing it" do
    assert [hint] = Hints.for(:check, %{})
    assert hint.tool == "script_author"
    assert hint.action == "create"
    assert hint.example == nil
  end

  test "remove and unknown contexts emit nothing" do
    assert Hints.for(:remove, %{}) == []
    assert Hints.for(:create, %{}) == []
  end
end
