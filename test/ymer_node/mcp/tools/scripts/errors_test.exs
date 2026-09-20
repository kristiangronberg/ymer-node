defmodule YmerNode.Mcp.Tools.Scripts.ErrorsTest do
  @moduledoc """
  Pure translation, so `async: true`.

  Each case asserts the **next call** the message names, not its wording. That
  is the contract: an agent reads these to decide what to do, and a message that
  merely describes the fault leaves it guessing.
  """
  use ExUnit.Case, async: true

  alias YmerNode.Mcp.Tools.Scripts.Errors

  test "an unaccepted script names both doors that can accept it" do
    message = Errors.format({:not_accepted, "hex is not accepted at its current code"})

    assert message =~ "script_author accept"
    assert message =~ "ymer-node scripts accept"
  end

  test "a missing script steers at list, an unknown action at describe" do
    assert Errors.format({:not_found, "no script named hex"}) =~ "`list`"
    assert Errors.format({:unknown_action, "hex has no action fetch"}) =~ "`describe`"
    assert Errors.format({:invalid_args, "hex fetch: #/url is required"}) =~ "`describe`"
  end

  test "a script that will not compile steers at the update that fixes it" do
    message = Errors.format({:not_loaded, "hex: syntax_error — script:hex:3: oops"})

    assert message =~ "script_author update"
    assert message =~ "describe"
  end

  @tag doc: """
       A timeout must say that what the run already did outside this node
       stands. It is the one refusal where retrying blindly can do the work
       twice — a payment, a ticket, a POST — and the node cannot know which.
       """
  test "a timeout warns before a retry rather than after" do
    message = Errors.format({:timeout, "hex fetch: no answer in 30000 ms, run killed"})

    assert message =~ "stands"
    assert message =~ "write mark"
  end

  test "names the script's own faults as the script's, not the caller's" do
    assert Errors.format({:bad_return, "hex ping: run/3 must answer"}) =~ "the script's bug"
    assert Errors.format({:result_not_encodable, "hex ping: #PID<0.1.0>"}) =~ "the script's bug"

    assert Errors.format({:invalid_schema, "hex fetch: invalid_type"}) =~
             "the script's bug, not the call's"
  end

  test "a build without docs names where else the contract is written" do
    message = Errors.format({:docs_missing, "this build carries no docs for YmerNode.Script"})

    assert message =~ "YmerNode.Script.Context"
    assert message =~ "published docs"
    assert message =~ "hexdocs"
  end

  test "an unknown package name steers at the guide's table" do
    message = Errors.format({:unknown_package, "no promised package is named \"json\""})

    assert message =~ "`guide`"
    assert message =~ "`JSON`"
  end

  test "renders a wrong-typed argument with what it should have been" do
    reason = {:wrong_type, %{key: "script", expected: "a string", got: 123}}

    assert Errors.format(reason) == "`script` must be a string, got 123."
  end

  test "falls through on a reason nothing here names" do
    assert Errors.format(:surprise, %{action_verb: "run a script"}) =~
             "Failed to run a script: :surprise"

    assert Errors.format(:surprise) =~ "Operation failed: :surprise"
  end
end
