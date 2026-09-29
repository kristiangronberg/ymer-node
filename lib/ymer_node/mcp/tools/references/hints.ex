defmodule YmerNode.Mcp.Tools.References.Hints do
  @moduledoc """
  Follow-up hints for the `references` tool, keyed off the hint_context maps
  `YmerNode.Mcp.Tools.References.Actions` produces.

  Only add and update steer. After them the natural next step is viewing the
  reference — and that includes the duplicate-add path, where the steer to the
  EXISTING reference is the response's whole point. Every other action emits
  nothing: find and list results already carry each reference's derived source
  and, where one is derivable, its recipe; a `read` or `refresh` answer carries
  the entry's age and where the next window starts; and `watch` answers the
  watch itself — a hint on any of them would be noise on a response that is
  already complete.
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
