defmodule YmerNode.Mcp.Tools.Scripts.Hints do
  @moduledoc """
  Follow-up hints for the `scripts` tool, keyed off the hint_context maps
  `YmerNode.Mcp.Tools.Scripts.Actions` produces.

  `describe` steers twice, and `list` and `run` never: `list` names many
  scripts and could not pick one; `run`'s response is the answer the caller
  wanted. The first hint is at `run`, only when the script can actually run;
  the second is at sharing — `script_author check` on the receiving node —
  whenever the code was asked for, whatever the script's state, because
  sharing needs the bytes and nothing else.

  A `describe` on a script that is unaccepted or would not compile deliberately
  emits **no** run hint. Steering a worker at a call the node is about to refuse
  wastes a turn and reads as the node contradicting itself; the refusal message
  it would meet already names the fix, and the action layer is what decides by
  putting a runnable action in the hint context or leaving it out.
  """
  alias Wymcp.Hint

  def for(:describe, hint_context) when is_map(hint_context) do
    run_hint(hint_context) ++ sharing_hint(hint_context)
  end

  def for(_action, _hint_context), do: []

  defp run_hint(%{script: script, action: action}) do
    [
      Hint.new(
        tool: "scripts",
        action: "run",
        description: "Run #{script}'s #{action} action",
        example: %{data: %{script: script, action: action, args: %{}}}
      )
    ]
  end

  defp run_hint(_hint_context), do: []

  # No example, for the reason `script_author`'s own check hint carries none:
  # the caller holds the code, and echoing it would double the answer.
  defp sharing_hint(%{script: script, code: true}) do
    [
      Hint.new(
        tool: "script_author",
        action: "check",
        description:
          "To share #{script}, hand this code to the receiving node's session: " <>
            "`check` then `create` there make it that node's own script, and the " <>
            "person there sets the secrets `declarations` names"
      )
    ]
  end

  defp sharing_hint(_hint_context), do: []
end
