defmodule YmerNode.Mcp.Tools.References.Hints do
  @moduledoc """
  Follow-up hints for the `references` tool, keyed off the hint_context maps
  `YmerNode.Mcp.Tools.References.Actions` produces.

  Only the write actions steer. After add and update the natural next step is
  viewing the reference — and that includes the duplicate-add path, where the
  steer to the EXISTING reference is the response's whole point. Read actions
  emit nothing: find and list results already carry each reference's derived
  source and, where one is derivable, its recipe, so a hint there would be noise
  on a response that is already complete.
  """

  alias Wymcp.Hint

  def for(action, %{id: id}) when action in [:add, :update] do
    [
      Hint.new(
        tool: "references",
        action: "get",
        description: "View the reference",
        example: %{data: %{id: id}}
      )
    ]
  end

  def for(_action, _hint_context), do: []
end
