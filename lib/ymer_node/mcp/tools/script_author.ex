defmodule YmerNode.Mcp.Tools.ScriptAuthor do
  @moduledoc """
  Wymcp tool `script_author` — writing the scripts this node accepts.

  A thin boundary over `YmerNode.Scripts`'s write verbs, wiring only the
  framework's callbacks. What a script is, what acceptance means, and what it
  refuses live in the context's own moduledoc.

  Destructive and **closed-world**, unlike its sibling
  `YmerNode.Mcp.Tools.Scripts`. Nothing here reaches past this machine: the tool
  compiles code into this VM and writes rows into this node's database, and it
  never runs an action. Running is `scripts`, and that is what carries the
  open-world mark.

  ## Why it is a separate tool

  Storing code here is accepting it: the node will run those bytes, with the
  node's own permissions, until someone changes or removes them. Keeping the
  write verbs on their own tool is what lets a client be granted the ability to
  run what has been accepted without being granted the ability to accept
  anything — a per-tool decision the human makes once, rather than a judgement
  the node has to make per call.

  That is also why `description/0` carries a line addressed to a person rather
  than to a worker. It is the only text this node can put in front of whoever is
  setting that permission, and the README's `Running it` carries the same
  recommendation for readers who never see it.
  """
  use Wymcp.Tool

  alias YmerNode.Mcp.Tools.ScriptAuthor.{Actions, Errors, Schemas}
  alias YmerNode.Mcp.Tools.ScriptAuthor.Hints, as: ScriptAuthorHints

  @impl true
  def name, do: "script_author"

  @impl true
  def title, do: "Script Author"

  @impl true
  def annotations, do: %{"destructiveHint" => true, "openWorldHint" => false}

  @impl true
  def description,
    do:
      "Write the scripts this node runs: check compiles code and reports what " <>
        "it would become, create and update store it, accept marks stored code " <>
        "accepted, remove deletes it. A script is a small Elixir module named " <>
        "Script.<Name>; storing one accepts it, and the node will run those " <>
        "bytes with its own permissions until they change. Needs approval: this " <>
        "is the tool that decides what code this machine will run — set it to " <>
        "ask, and read what it is storing."

  @impl true
  def actions, do: Schemas.all()

  @impl true
  def run_action(action, data, _ctx), do: Actions.run(action, data)

  @impl true
  def hints(action, hint_context), do: ScriptAuthorHints.for(action, hint_context)

  @impl true
  def handle_error({reason, ctx}) when is_map(ctx), do: Errors.format(reason, ctx)
  def handle_error(reason), do: Errors.format(reason)
end
