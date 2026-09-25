defmodule YmerNode.Mcp.Tools.Schedules do
  @moduledoc """
  Wymcp tool `schedules` — adding, listing, updating and removing the standing
  instructions `YmerNode.Schedules` fires.

  A thin boundary over that context, wiring only the framework's callbacks. What
  a schedule is, what `add` refuses and what a firing skips live in the
  context's own moduledoc.

  Destructive and open-world, like `YmerNode.Mcp.Tools.Scripts`. The tool itself
  runs nothing, but what it adds runs a script's action later — with nobody
  watching, for as long as the schedule lives — and a script reaches the network
  with the node's own permissions.

  ## Why it is a separate tool

  Adding a schedule grants runs nobody will be there to see, up to 90 days of
  them. A tool of its own is what lets a client run what has been accepted
  without being able to set it running unattended: a per-tool permission the
  person sets once. That is why `description/0` carries a line addressed to that
  person, as `YmerNode.Mcp.Tools.ScriptAuthor`'s does.
  """
  use Wymcp.Tool

  alias YmerNode.Mcp.Tools.Schedules.{Actions, Errors, Schemas}

  @impl true
  def name, do: "schedules"

  @impl true
  def title, do: "Schedules"

  @impl true
  def annotations, do: %{"destructiveHint" => true, "openWorldHint" => true}

  @impl true
  def description,
    do:
      "Standing instructions for this node to run one action of one accepted " <>
        "script, with fixed args, on a five-field cron expression in the node's " <>
        "time zone, until the schedule's lifetime ends — 90 days at most. add " <>
        "answers the end and the next firing; list shows every schedule with its " <>
        "next firing, its end or that it expired, and its last run; update " <>
        "changes the cron expression, the args or the lifetime; remove deletes " <>
        "one. A firing the node was not up for is skipped, and so is one while " <>
        "the schedule's previous run is still in flight. Needs approval: a " <>
        "schedule runs its action — possibly one that writes — with nobody " <>
        "watching, for as long as it lives; set it to ask, and read what it is " <>
        "adding."

  @impl true
  def actions, do: Schemas.all()

  @impl true
  def run_action(action, data, _ctx), do: Actions.run(action, data)

  @impl true
  def handle_error({reason, ctx}) when is_map(ctx), do: Errors.format(reason, ctx)
  def handle_error(reason), do: Errors.format(reason)
end
