defmodule YmerNode.Mcp.Tools.ScriptAuthor.ErrorsTest do
  @moduledoc """
  Pure translation, so `async: true`. Each case asserts the next call a message
  names, or the fact an author cannot proceed without — never the wording.

  The coverage case at the end is the one that matters over time: it walks every
  reason `YmerNode.Scripts.Compiler` and acceptance can answer and asserts none
  of them falls through to the catch-all, whose `inspect/1` output is not a
  message anyone can act on.
  """
  use ExUnit.Case, async: true

  alias YmerNode.Mcp.Tools.ScriptAuthor.Errors

  @compiler_reasons [
    :syntax_error,
    :no_module,
    :module_outside_script,
    :several_top_modules,
    :dynamic_module_name,
    :compile_error,
    :compile_timeout,
    :missing_contract,
    :unknown_contract,
    :missing_callbacks,
    :metadata_raised,
    :metadata_timeout,
    :invalid_description,
    :invalid_actions,
    :invalid_declarations
  ]

  @acceptance_reasons [
    :not_found,
    :name_taken,
    :name_mismatch,
    :module_mismatch,
    :reserved_name,
    :host_claimed,
    :throttle_conflict,
    :run_in_flight,
    :commit_failed
  ]

  test "a missing contract names the line to add" do
    assert Errors.format({:missing_contract, "the code does not `use YmerNode.Script`"}) =~
             "Add `use YmerNode.Script`"
  end

  test "a module outside Script. says why the rule exists" do
    message = Errors.format({:module_outside_script, "Enum is defined outside Script."})

    assert message =~ "keeps a script from redefining"
  end

  test "a metadata timeout says where the work belongs instead" do
    assert Errors.format({:metadata_timeout, "no answer in 5000 ms"}) =~ "put the work in run/3"
  end

  test "a claimed host explains the one-host-one-script rule" do
    message = Errors.format({:host_claimed, "hex.pm is already claimed by hex"})

    assert message =~ "resolve the same way every time"
  end

  test "a throttle conflict says why one name takes one set of parameters" do
    message = Errors.format({:throttle_conflict, "acct is declared by the accepted script a"})

    assert message =~ "its parameters must agree"
  end

  test "a run in flight says the wait is bounded" do
    assert Errors.format({:run_in_flight, "hex has a run in flight"}) =~
             "5 minutes at the very most"
  end

  test "renders a changeset the way every other tool does" do
    changeset =
      Ecto.Changeset.add_error(
        Ecto.Changeset.change(%YmerNode.Scripts.Script{}),
        :name,
        "has invalid format"
      )

    assert Errors.format(changeset) =~ "name: has invalid format"
  end

  test "renders a wrong-typed argument with what it should have been" do
    assert Errors.format({:wrong_type, %{key: "code", expected: "a string", got: 7}}) ==
             "`code` must be a string, got 7."
  end

  @tag doc: """
       Every reason the compiler and acceptance can produce must have a clause
       of its own. A reason that falls through reaches the catch-all and is
       rendered as `inspect/1` — `{:invalid_actions, "action fetch: ..."}` shown
       raw — which is not something an author can act on, and the failure is
       silent because the call still succeeds in returning *a* string.
       """
  test "no reason this tool can answer falls through to the catch-all" do
    for reason <- @compiler_reasons ++ @acceptance_reasons do
      message = Errors.format({reason, "the detail"})

      refute message =~ "Operation failed:",
             "#{reason} has no clause of its own and fell through"

      refute message =~ inspect({reason, "the detail"}),
             "#{reason} was rendered through inspect/1 rather than translated"
    end
  end

  test "still falls through on a reason nothing here names" do
    assert Errors.format(:surprise, %{action_verb: "create a script"}) =~
             "Failed to create a script: :surprise"

    assert Errors.format(:surprise) =~ "Operation failed: :surprise"
  end
end
