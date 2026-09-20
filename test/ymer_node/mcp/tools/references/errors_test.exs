defmodule YmerNode.Mcp.Tools.References.ErrorsTest do
  @moduledoc """
  Every message is rendered for an agent deciding what to do next, so each
  assertion pins the recovery the message names rather than its exact wording.
  Pure — no database — so `async: true`.
  """
  use ExUnit.Case, async: true

  alias YmerNode.Mcp.Tools.References.Errors
  alias YmerNode.References.Reference

  test "each distinct reason names the call that recovers from it" do
    assert Errors.format(:not_found) =~ "Verify the id"
    assert Errors.format(:invalid_id) =~ "positive integer"
    assert Errors.format(:empty_query) =~ "omit it and filter instead"
    assert Errors.format(:empty_find) =~ "query, tags, or a source"
    assert Errors.format(:empty_find) =~ "list"
    assert Errors.format(:invalid_tags) =~ "JSON array"
    assert Errors.format(:invalid_limit) =~ "1–100"
  end

  @tag doc: """
       The invalid-source message lists the vocabulary in force at call time,
       never a compile-time copy — it is the only way a caller that guessed a
       source learns which ones this node actually has. A failure once scripts
       land means the message froze to the built-ins and stopped naming accepted
       scripts, leaving a caller no way to discover them.
       """
  test "the invalid-source message lists the current vocabulary" do
    message = Errors.format(:invalid_source, %{declarations: []})

    for built_in <- ["file", "other", "web"] do
      assert message =~ built_in
    end
  end

  @tag doc: """
       When the action put its declarations on the context, the message names
       the vocabulary THAT call was judged against rather than one from a fresh
       read. A failure means the message and the refusal could disagree — a
       caller told a script is invalid and then shown it in the valid list, or
       the reverse, if a script were accepted between the two reads.
       """
  test "the invalid-source message uses the context's declarations when it has them" do
    declarations = [%{name: "tracker", hosts: ["tracker.example.fi"], action: "issue"}]
    message = Errors.format(:invalid_source, %{declarations: declarations})

    assert message =~ "tracker"
    assert message =~ "file, other, tracker, web"
  end

  test "a changeset renders as field-by-field guidance with interpolations applied" do
    changeset = Reference.changeset(%Reference{}, %{title: "E", uri: "https://x"})
    message = Errors.format(changeset)

    assert message =~ "- title: should be at least 2 character(s)"
    refute message =~ "%{count}"
  end

  test "an unknown reason falls back, naming the action verb when there is one" do
    assert Errors.format(:something_new, %{action_verb: "find references"}) =~
             "Failed to find references"

    assert Errors.format(:something_new) =~ "Operation failed"
  end
end
