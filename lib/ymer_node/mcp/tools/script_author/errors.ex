defmodule YmerNode.Mcp.Tools.ScriptAuthor.Errors do
  @moduledoc """
  Translates the `script_author` tool's error reasons into messages a worker can
  act on. Called by `YmerNode.Mcp.Tools.ScriptAuthor`'s
  `c:Wymcp.Tool.handle_error/1`.

  Two sources, and the split is worth knowing when you add a clause. The
  **compiler** refuses code before a row exists — every reason
  `YmerNode.Scripts.Compiler` can answer arrives here, and the detail it carries
  is already the diagnostic, so most clauses add the next call and nothing else.
  **Acceptance** refuses what the compiler cannot see, because it depends on the
  other rows.

  Deliberately not shared with `YmerNode.Mcp.Tools.Scripts.Errors`: nothing here
  can reach that tool, which compiles nothing and accepts nothing, and nothing
  there but `:not_found` can reach this one.
  """
  alias YmerNode.Mcp.Tools.Helpers

  @author "Fix the code and call `check` before storing it again."

  def format(reason, ctx \\ %{}), do: message(reason, ctx)

  def message(%Ecto.Changeset{} = changeset, _ctx),
    do: Helpers.format_changeset_errors(changeset)

  def message({:not_found, detail}, _ctx),
    do: "#{detail}. Call `scripts list` to see what this node holds."

  # ─── Acceptance, which the compiler cannot decide ───────────────────

  def message({:name_taken, detail}, _ctx), do: detail <> "."

  def message({:name_mismatch, detail}, _ctx), do: detail <> "."

  def message({:module_mismatch, detail}, _ctx), do: detail <> "."

  def message({:reserved_name, detail}, _ctx),
    do: "#{detail}. Rename the module and try again."

  def message({:host_claimed, detail}, _ctx),
    do:
      "#{detail}. One host is claimed by one script, so that references resolve " <>
        "the same way every time. Remove the other script's claim, or drop this one."

  def message({:throttle_conflict, detail}, _ctx),
    do:
      "#{detail}. A throttle is one process per name, shared by every script declaring it, " <>
        "so its parameters must agree: declare the same ones, or a name of this script's own."

  def message({:run_in_flight, detail}, _ctx),
    do:
      "#{detail}. A run is bounded by its own deadline — 5 minutes at the very " <>
        "most — so the wait is finite."

  # The store itself failed inside the loader's message — the database, not
  # the code — and the loader put the stored script back before answering.
  def message({:commit_failed, detail}, _ctx),
    do:
      "The write did not land: #{detail}. The stored code is back in place, so " <>
        "the same call can be retried."

  # ─── The compiler, whose detail is already the diagnostic ───────────

  def message({:syntax_error, detail}, _ctx), do: "The code does not parse: #{detail}"
  def message({:compile_error, detail}, _ctx), do: "The code does not compile: #{detail}"

  def message({:compile_timeout, detail}, _ctx),
    do:
      "The code did not finish compiling: #{detail}. A module body runs while it " <>
        "compiles, so a loop or a sleep written outside a function never returns — " <>
        "move that work into run/3."

  def message({:no_module, _detail}, _ctx),
    do: "The code defines no module. It must be one `defmodule Script.<Name>`."

  def message({:module_outside_script, detail}, _ctx),
    do:
      "#{detail}. Every module in a script lives under `Script.` — that is what " <>
        "keeps a script from redefining something this node depends on."

  def message({:several_top_modules, detail}, _ctx),
    do: "#{detail}. One script is one top-level module; nest the rest under it."

  def message({:dynamic_module_name, detail}, _ctx),
    do: "#{detail}. The name has to be readable from the code without running it."

  def message({:missing_contract, detail}, _ctx),
    do: "#{detail}. Add `use YmerNode.Script` as the module's first line."

  def message({:unknown_contract, detail}, _ctx),
    do: "#{detail}. This node speaks a different contract version than the code was written for."

  def message({:missing_callbacks, detail}, _ctx),
    do: "The script does not implement: #{detail}. All four are required."

  def message({:invalid_description, detail}, _ctx), do: "#{detail} #{@author}"
  def message({:invalid_actions, detail}, _ctx), do: "#{detail} #{@author}"
  def message({:invalid_declarations, detail}, _ctx), do: "#{detail} #{@author}"

  def message({:metadata_raised, detail}, _ctx),
    do: "The script raised while reporting itself: #{detail} #{@author}"

  def message({:metadata_timeout, detail}, _ctx),
    do:
      "The script did not finish reporting itself: #{detail}. " <>
        "description/0, actions/0 and declarations/0 must answer immediately — " <>
        "put the work in run/3."

  # The wrong-typed twins the action layer raises before anything is compiled.
  def message({:wrong_type, %{key: key, expected: expected, got: got}}, _ctx),
    do: "`#{key}` must be #{expected}, got #{inspect(got)}."

  def message(reason, %{action_verb: verb}), do: "Failed to #{verb}: #{inspect(reason)}"
  def message(reason, _ctx), do: "Operation failed: #{inspect(reason)}"
end
