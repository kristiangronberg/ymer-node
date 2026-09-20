defmodule YmerNode.Mcp.Tools.Scripts.HintsTest do
  use ExUnit.Case, async: true

  alias YmerNode.Mcp.Tools.Scripts.Hints

  test "describe steers at running the script" do
    assert [hint] = Hints.for(:describe, %{script: "hex", action: "package"})
    assert hint.tool == "scripts"
    assert hint.action == "run"
    assert hint.example == %{data: %{script: "hex", action: "package", args: %{}}}
  end

  @tag doc: """
       A describe on a script that cannot run must emit NO hint. The action
       layer signals that by handing over an empty context. A failure here means
       a worker is steered at a `run` the node is about to refuse — a wasted
       turn, and the node appearing to contradict itself.
       """
  test "emits nothing for a script that could not be run" do
    assert Hints.for(:describe, %{}) == []
  end

  test "describe steers at sharing as well when the code was asked for" do
    assert [run, share] = Hints.for(:describe, %{script: "hex", action: "package", code: true})
    assert run.action == "run"
    assert share.tool == "script_author"
    assert share.action == "check"
    assert share.description =~ "receiving node"
    assert share.example == nil
  end

  @tag doc: """
       Sharing needs the bytes and nothing else, so the hint does not wait for
       the script to be runnable: an unaccepted script, or one this boot could
       not compile, still shares. A failure means a worker holding the code was
       told nothing about where it goes.
       """
  test "a script that cannot run still shares when its code was asked for" do
    assert [share] = Hints.for(:describe, %{script: "hex", code: true})
    assert share.action == "check"
  end

  test "list and run emit nothing" do
    assert Hints.for(:list, %{}) == []
    assert Hints.for(:run, %{script: "hex", action: "package"}) == []
  end
end
