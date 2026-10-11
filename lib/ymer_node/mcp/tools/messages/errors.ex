defmodule YmerNode.Mcp.Tools.Messages.Errors do
  @moduledoc """
  Translates the `messages` tool's error reasons into error messages a worker
  can act on. Called by `YmerNode.Mcp.Tools.Messages`'s `c:Wymcp.Tool.handle_error/1`.

  Only refusals arrive here. An answer that finds nothing is not an error: it is
  an answer, and it says when messages started (`YmerNode.Messages`).
  """

  def format(reason, ctx \\ %{}), do: message(reason, ctx)

  def message({:body_too_large, detail}, _ctx),
    do:
      "#{detail}. Put the content in a file in the files directory, or in a notebook " <>
        "row, and send where it is."

  def message({:name_too_long, detail}, _ctx),
    do: "#{detail}. Choose a shorter one — a task's name or a table/row reference is enough."

  def message({:read_needs_thread, detail}, _ctx),
    do:
      "#{detail}. last and before page through messages: name the thread, or give since " <>
        "to read every thread from then on. read {} alone answers the thread index."

  def message({:invalid_since, detail}, _ctx),
    do:
      "#{detail}. Give a span back from now such as PT1H, or a date-time such as " <>
        "2026-10-11T09:00:00, or 2026-10-11T09:00:00+03:00 with an offset."

  # The wrong-typed twins the action layer raises before anything is called.
  def message({:wrong_type, %{key: key, expected: expected, got: got}}, _ctx),
    do: "`#{key}` must be #{expected}, got #{inspect(got)}."

  def message(reason, %{action_verb: verb}), do: "Failed to #{verb}: #{inspect(reason)}"
  def message(reason, _ctx), do: "Operation failed: #{inspect(reason)}"
end
