defmodule YmerNode.Mcp.Tools.Scripts do
  @moduledoc """
  Wymcp tool `scripts` — the scripts this node has accepted, and running one.

  A thin boundary over `YmerNode.Scripts`, wiring only the framework's
  callbacks. What a script is, what acceptance means, and why a run is bounded
  and killed rather than waited on live in the context's own moduledoc and in
  `YmerNode.Scripts.Runner`'s.

  Destructive **and** open-world, which no other tool on this node is. A script
  reaches the network with the node's own permissions, so `run` is the one call
  here whose effects can land outside this machine and outside this node's
  control — and the node cannot tell, in advance, which script will. Both hints
  are properties of the tool, not of the average call.

  Authoring lives next door in `YmerNode.Mcp.Tools.ScriptAuthor`. The split is
  the point: a client can be granted the ability to run what has been accepted
  without being granted the ability to accept anything.
  """
  use Wymcp.Tool

  alias YmerNode.Mcp.Tools.Scripts.{Actions, Errors, Schemas}
  alias YmerNode.Mcp.Tools.Scripts.Hints, as: ScriptsHints

  @impl true
  def name, do: "scripts"

  @impl true
  def title, do: "Scripts"

  @impl true
  def annotations, do: %{"destructiveHint" => true, "openWorldHint" => true}

  @impl true
  def description,
    do:
      "Small Elixir modules this node has accepted, each serving named actions " <>
        "— reaching systems the node has no built-in support for, and " <>
        "supplying the fetch recipes references hands you. list names them; " <>
        "describe gives one script's actions with their arguments and their " <>
        "write marks; run executes one; guide renders the contract and the " <>
        "batteries, for writing one; info renders a promised package's own docs " <>
        "from this release, for the first script that uses it. Read describe " <>
        "before you run: a run can reach the network and change things outside " <>
        "this machine, and it is killed rather than waited on past its deadline. " <>
        "Only a script accepted at exactly the code it holds will run."

  @impl true
  def actions, do: Schemas.all()

  @impl true
  def run_action(action, data, _ctx), do: Actions.run(action, data)

  @impl true
  def hints(action, hint_context), do: ScriptsHints.for(action, hint_context)

  @impl true
  def handle_error({reason, ctx}) when is_map(ctx), do: Errors.format(reason, ctx)
  def handle_error(reason), do: Errors.format(reason)
end
