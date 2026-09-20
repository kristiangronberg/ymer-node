defmodule YmerNode.Mcp.Tools.ScriptAuthor.Hints do
  @moduledoc """
  Follow-up hints for the `script_author` tool, keyed off the hint_context maps
  `YmerNode.Mcp.Tools.ScriptAuthor.Actions` produces.

  The write verbs steer at the OTHER tool. After `create`, `update` or `accept`
  the natural next step is running the thing that was just stored, and `run`
  lives on `scripts` — a client granted only this tool will not have it, which
  is exactly the arrangement the two-tool split exists for, and a hint it cannot
  follow is cheaper than a surface that pretends the two are one.

  `check` steers at `create`, because that is what a caller checks *for* — and
  carries no example. The one thing `create` needs is the code the caller has
  just sent, and echoing it back would double the answer to the one call in
  this tool whose input is long: this repo's own stance is that a script's code
  is long enough to be off by default on `scripts describe`.
  `remove` steers nowhere: there is nothing left to look at.
  """
  alias Wymcp.Hint

  def for(action, %{script: script}) when action in [:create, :update, :accept] do
    [
      Hint.new(
        tool: "scripts",
        action: "describe",
        description: "See #{script}'s actions and their arguments",
        example: %{data: %{script: script}}
      )
    ]
  end

  def for(:check, _hint_context) do
    [
      Hint.new(
        tool: "script_author",
        action: "create",
        description: "Create this script and accept it — the same code, as `code`"
      )
    ]
  end

  def for(_action, _hint_context), do: []
end
