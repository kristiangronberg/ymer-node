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

  Deliberately not shared with `YmerNode.Mcp.Tools.Scripts.Errors`, which
  compiles nothing and accepts nothing. Beside the wrong-typed twins every tool
  renders, the two meet at `:not_found` and the three library reasons, which a
  run answers too, with a run's own fix.
  """
  alias YmerNode.Mcp.Tools.Helpers

  @author "Fix the code and call `check` before storing it again."

  @libraries "`scripts list` shows the libraries this node holds and their versions."

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

  def message({:fallback_claimed, detail}, _ctx),
    do:
      "#{detail}. One script serves the web pages no host claim takes, so that a " <>
        "page resolves the same way every time. Drop this script's web_fallback, " <>
        "or remove the other's."

  def message({:throttle_conflict, detail}, _ctx),
    do:
      "#{detail}. A throttle is one process per name, shared by every script declaring it, " <>
        "so its parameters must agree: declare the same ones, or a name of this script's own."

  def message({:library_missing, detail}, _ctx), do: "#{detail}. #{@libraries}"
  def message({:library_broken, detail}, _ctx), do: "#{detail}. #{@libraries}"
  def message({:library_out_of_range, detail}, _ctx), do: "#{detail}. #{@libraries}"

  def message({:requirement_broken, detail}, _ctx), do: detail <> "."
  def message({:library_in_use, detail}, _ctx), do: detail <> "."
  def message({:version_unchanged, detail}, _ctx), do: detail <> "."

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
    do:
      "The code defines no module. It must be one `defmodule Script.<Name>`, or " <>
        "`defmodule Library.<Name>` for a library."

  def message({:module_outside_script, detail}, _ctx),
    do:
      "#{detail}. Every module in a script lives under `Script.`, and in a library " <>
        "under `Library.` — that is what keeps a script from redefining something " <>
        "this node depends on."

  def message({:several_top_modules, detail}, _ctx),
    do: "#{detail}. One script is one top-level module; nest the rest under it."

  def message({:dynamic_module_name, detail}, _ctx),
    do: "#{detail}. The name has to be readable from the code without running it."

  def message({:missing_contract, detail}, _ctx),
    do:
      "#{detail}. Add `use YmerNode.Script` as the module's first line, or " <>
        "`use YmerNode.Library` for a library."

  def message({:contract_mismatch, detail}, _ctx), do: detail <> "."

  def message({:undeclared_library, detail}, _ctx), do: "#{detail}. #{@author}"

  def message({:unknown_contract, detail}, _ctx),
    do: "#{detail}. This node speaks a different contract version than the code was written for."

  def message({:missing_callbacks, detail}, _ctx),
    do: "The code does not implement #{detail}."

  def message({:invalid_description, detail}, _ctx), do: "#{detail} #{@author}"
  def message({:invalid_version, detail}, _ctx), do: "#{detail}. #{@author}"
  def message({:invalid_actions, detail}, _ctx), do: "#{detail} #{@author}"
  def message({:invalid_declarations, detail}, _ctx), do: "#{detail} #{@author}"

  def message({:metadata_raised, detail}, _ctx),
    do: "The script raised while reporting itself: #{detail} #{@author}"

  def message({:metadata_timeout, detail}, _ctx),
    do:
      "The script did not finish reporting itself: #{detail}. " <>
        "description/0, version/0, actions/0 and declarations/0 must answer immediately — " <>
        "put the work in run/3."

  # The wrong-typed twins the action layer raises before anything is compiled.
  def message({:wrong_type, %{key: key, expected: expected, got: got}}, _ctx),
    do: "`#{key}` must be #{expected}, got #{inspect(got)}."

  def message(reason, %{action_verb: verb}), do: "Failed to #{verb}: #{inspect(reason)}"
  def message(reason, _ctx), do: "Operation failed: #{inspect(reason)}"
end
