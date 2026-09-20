defmodule YmerNode.Mcp.Tools.Scripts.Errors do
  @moduledoc """
  Translates the `scripts` tool's error reasons into messages a worker can act
  on. Called by `YmerNode.Mcp.Tools.Scripts`'s `c:Wymcp.Tool.handle_error/1`.

  Every message names the next call rather than describing the fault: the reader
  is an agent deciding what to do next, not a person reading a log.

  The set is the one `YmerNode.Scripts.Runner`'s moduledoc tabulates, plus
  `:not_found`, the two documentation refusals — a build without the `Docs`
  chunk, a package name outside the promise — and the wrong-typed twins the
  action layer raises. It is
  deliberately **not** shared with `YmerNode.Mcp.Tools.ScriptAuthor.Errors`:
  nothing the compiler or acceptance refuses can reach this tool, because this
  tool compiles nothing and accepts nothing — the runner flattens the one compile
  failure it can see into the text of `:not_loaded`. A shared module would be a
  union neither tool fully uses.
  """

  def format(reason, ctx \\ %{}), do: message(reason, ctx)

  def message({:not_found, detail}, _ctx),
    do: "#{detail}. Call `list` to see what this node holds."

  def message({:not_accepted, detail}, _ctx),
    do:
      "#{detail}. Accept it with `script_author accept`, or from the machine " <>
        "itself with `ymer-node scripts accept`."

  def message({:not_loaded, detail}, _ctx),
    do:
      "#{detail}. The script is stored but this node could not compile it — " <>
        "`describe` shows the diagnostics, and `script_author update` is the fix."

  def message({:unknown_action, detail}, _ctx),
    do: "#{detail}. Call `describe` for this script's actions and their arguments."

  def message({:invalid_args, detail}, _ctx),
    do: "#{detail}. Call `describe` for the action's properties and required list."

  def message({:invalid_schema, detail}, _ctx),
    do:
      "#{detail}. The script's own argument schema is malformed — this is the " <>
        "script's bug, not the call's; report it to whoever maintains it."

  def message({:timeout, detail}, _ctx),
    do:
      "#{detail}. Anything the run had already done outside this node stands — " <>
        "check before retrying if the action's write mark is true."

  def message({:script_raised, detail}, _ctx), do: "The script failed: #{detail}"
  def message({:script_exited, detail}, _ctx), do: "The run died: #{detail}"
  def message({:script_error, detail}, _ctx), do: "The script refused: #{detail}"

  def message({:bad_return, detail}, _ctx),
    do: "#{detail}. That is the script's bug — the contract is in `YmerNode.Script`."

  def message({:result_not_encodable, detail}, _ctx),
    do:
      "#{detail}. The action ran; its answer cannot travel over JSON, so nothing " <>
        "could be returned. That is the script's bug."

  def message({:docs_missing, detail}, _ctx),
    do:
      "#{detail}. The guide's text is the moduledoc of `YmerNode.Script` and of " <>
        "`YmerNode.Script.Context`, in the code and in the published docs; a " <>
        "package's docs are on hexdocs at the line the guide's table names."

  def message({:unknown_package, detail}, _ctx),
    do:
      "#{detail}. The table in `guide` is where these names come from; `JSON` is " <>
        "Elixir's own and the context is in the guide itself, so neither has a page here."

  # The wrong-typed twins the action layer raises before anything is called.
  def message({:wrong_type, %{key: key, expected: expected, got: got}}, _ctx),
    do: "`#{key}` must be #{expected}, got #{inspect(got)}."

  def message(reason, %{action_verb: verb}), do: "Failed to #{verb}: #{inspect(reason)}"
  def message(reason, _ctx), do: "Operation failed: #{inspect(reason)}"
end
