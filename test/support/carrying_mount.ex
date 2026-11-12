defmodule YmerNode.CarryingMount.Ui do
  @moduledoc """
  The carrying application's own tool in `YmerNode.CarryingMount`: `show`
  answers `ok`, so a test can call a tool `ymer_node` does not serve, and
  `assigns` answers the keys of the assigns the tool was handed, so a test can
  see what the endpoint leaves in them. Defined ahead of the mount module in this file: the mount module loads every
  tool it names while it compiles, and a module later in the same file has not
  compiled yet.
  """
  use Wymcp.Tool

  @impl true
  def name, do: "ui"

  @impl true
  def description, do: "Stands in for a carrying application's own tool."

  @impl true
  def actions do
    %{
      show: %{description: "Answer ok", properties: %{}, required: [], defaults: %{}},
      assigns: %{
        description: "Answer the keys of the assigns this tool was handed",
        properties: %{},
        required: [],
        defaults: %{}
      }
    }
  end

  @impl true
  def run_action(:show, _data, _ctx), do: {:ok, %{message: "ok"}, %{}}

  def run_action(:assigns, _data, ctx),
    do: {:ok, %{keys: ctx.assigns |> Map.keys() |> Enum.map(&inspect/1)}, %{}}
end

defmodule YmerNode.CarryingMount do
  @moduledoc """
  Test support standing in for a carrying application's mount module, written
  the way `YmerNode.Mcp`'s doc tells a carrying application to write one: the
  node's tools first, then a tool of its own, with the node's instructions and
  serverInfo passed unchanged. It compiles with the test build, as a carrying
  application's compiles with its own.

  `YmerNode.PartialMount`, beside it, is the wrong one: a mount module that
  serves only some of the node's tools.
  """
  # Aliased ahead of `use`: the router's options are evaluated at this module's
  # compile, where an alias written below the `use` line is not yet in scope.
  alias YmerNode.CarryingMount.Ui
  alias YmerNode.Mcp.McpServer

  use Wymcp.Router,
    tools: YmerNode.Mcp.tools() ++ [Ui],
    instructions: McpServer.instructions(),
    server_info: YmerNode.Mcp.server_info()
end

defmodule YmerNode.PartialMount do
  @moduledoc """
  Test support: a mount module that leaves out every tool of the node's but
  the notebook, for the case `YmerNode.Mcp.mount/0` refuses.
  """
  use Wymcp.Router, tools: [YmerNode.Mcp.Tools.Notebook]
end
