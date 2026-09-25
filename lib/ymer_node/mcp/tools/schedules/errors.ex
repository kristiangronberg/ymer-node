defmodule YmerNode.Mcp.Tools.Schedules.Errors do
  @moduledoc """
  Translates the `schedules` tool's error reasons into messages a worker can act
  on. Called by `YmerNode.Mcp.Tools.Schedules`'s `c:Wymcp.Tool.handle_error/1`.

  Every message names the next call rather than describing the fault. The
  runner's pre-run refusals arrive here too, from `add` and `update`, which
  check a call the way a run would (`YmerNode.Scripts.Runner.check/3`); those
  messages already name the script and the action, so each clause adds only
  where to look next.
  """

  alias YmerNode.Mcp.Tools.Helpers

  def format(reason, ctx \\ %{}), do: message(reason, ctx)

  def message({:invalid_name, detail}, _ctx), do: "#{detail}."

  def message({:name_taken, detail}, _ctx), do: "#{detail}. `list` shows it."

  def message({:invalid_cron_expression, detail}, _ctx),
    do: "#{detail}. For example `0 7 * * MON-FRI`, `*/15 * * * *` or `@daily`."

  def message({:invalid_lifetime, detail}, _ctx),
    do: "#{detail}. Leave it out for 90 days."

  def message({:not_found, detail}, _ctx),
    do: "#{detail}. `list` names the schedules, and `scripts list` the scripts."

  def message({:not_accepted, detail}, _ctx),
    do:
      "#{detail}. Accept it with `script_author accept`, or from the machine itself " <>
        "with `ymer-node scripts accept`."

  def message({:not_loaded, detail}, _ctx),
    do: "#{detail}. `scripts describe` shows why it will not run."

  def message({:unknown_action, detail}, _ctx),
    do: "#{detail}. `scripts describe` lists the script's actions."

  def message({:invalid_args, detail}, _ctx),
    do: "#{detail}. `scripts describe` gives the action's properties and required list."

  def message({:invalid_schema, detail}, _ctx),
    do:
      "#{detail}. The script's own argument schema is malformed — the script's bug, " <>
        "not the call's."

  def message(%Ecto.Changeset{} = changeset, _ctx),
    do: "The schedule could not be stored: #{Helpers.format_changeset_errors(changeset)}"

  # The wrong-typed twins the action layer raises before anything is called.
  def message({:wrong_type, %{key: key, expected: expected, got: got}}, _ctx),
    do: "`#{key}` must be #{expected}, got #{inspect(got)}."

  def message(reason, %{action_verb: verb}), do: "Failed to #{verb}: #{inspect(reason)}"
  def message(reason, _ctx), do: "Operation failed: #{inspect(reason)}"
end
