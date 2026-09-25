defmodule YmerNode.Scripts.Runner do
  @moduledoc """
  One run — one execution of one action of one accepted script, whoever started
  it — and what is checked before it, the process it happens in, and the shape of
  every answer that comes back.

  A run never happens in the caller's process. Each one is a child of
  `YmerNode.Scripts.TaskSupervisor`, awaited with a deadline and killed when the
  deadline passes. That buys isolation from a crash and from a loop, and nothing
  else: it is **not a sandbox**. A run reaches the notebook, the network and the
  filesystem with the node's own permissions, because a script this node has
  accepted is a script this node trusts.

  ## Two bounded reads, not one

  Before a run can start, the node reads the script's own
  `c:YmerNode.Script.actions/0` — is there such an action, what arguments does it
  take, how long may it have — and its `c:YmerNode.Script.declarations/0`, which
  says what secrets the run may resolve. Both are script code, both can loop, so
  neither is called in the caller's process either.

  That is why a run is two tasks. The metadata read is bounded by a fixed five
  seconds, because the run's own deadline is a number that read has not fetched
  yet; the run that follows is bounded by the action's timeout. One task would
  mean choosing the deadline before knowing it.

  ## The deadline

  Thirty seconds unless the action asks for more, and never more than five
  minutes — `deadline/1` is the whole rule. The cap is the node's and not the
  script's: the node runs scripts on its own schedules (`YmerNode.Schedules`),
  with nobody waiting on the answer, and a run with no bound the node imposed
  would hold its slot forever.

  A run that passes its deadline is killed with `:brutal_kill` — no cleanup, no
  `terminate`. **Whatever it had already done outside this VM stands**: a row
  written, a request sent, a payment taken. That is the script's problem to make
  safe rather than the node's to undo, which is why every action carries a write
  mark and a worker is told to read before it writes.

  Native code cannot be interrupted: a run past its deadline is answered
  `:timeout` on time and its process is gone, while the native call runs to its
  end on a dirty scheduler, of which the node has one per core.

  The run's context carries the deadline too, as the instant it falls at, so a
  battery that waits — a throttle — can refuse a wait the run could not finish
  rather than sit in a queue until the kill.

  ## In flight

  A run registers itself in the `YmerNode.Scripts.Runs` registry — `:duplicate`,
  because one script may have several runs at once — and holds that entry for
  the **whole** of `run/3`, not for either task inside it. It is taken in the
  calling process and released in an `after`, so it covers the metadata read,
  the argument check that happens between the two tasks, and the run itself; the
  registry drops it anyway if that process dies, so nothing leaks from a caller
  that is killed.

  Each task takes a second entry of its own and arms a kill one second behind
  its deadline, because a caller can die mid-run — a client cancelling, an rpc
  interrupted — and the task is not linked to it. Without the entry the run
  would vanish from `in_flight?/1` while still executing, and a write could
  purge the tree under it; without the kill it would run past the cap with
  nobody waiting. While the caller lives its own `Task.yield` answers first,
  and the task drops its entry before it answers, so the backstop changes
  nothing a live caller sees — the moment `run/3` returns, `in_flight?/1` is
  false.

  One entry per call rather than one per task is what makes it mean anything. A
  run is two tasks with the node's own work between them, and an entry that
  disappeared with the first task would leave a window where a run in progress
  reads as no run at all.

  The order inside `run/3` is the other half: the entry is taken **before**
  `YmerNode.Scripts.Loader` is asked for the module. Nothing else hands out a
  script's module, and the loader refuses a purge while this entry stands, so a
  write either sees the run and is refused, or is already holding the loader and
  hands the run the tree it leaves. `in_flight?/1` is the same lookup, read by
  `YmerNode.Scripts` at its own doors for an early refusal with the name in it.
  The reason both exist: `:code.purge/1` kills a process still executing the old
  code, so landing a write over a live run would be the node breaking the same
  read-before-write rule it asks scripts to keep.

  ## Every answer

  A script's `{:ok, term}` is answered `{:ok, term}` — but only after the node
  has proved the term encodes to JSON. The answer's next stop is a JSON-RPC
  result, and a term that cannot be encoded there would surface as the node
  crashing rather than as the script being wrong. Checking here means the error
  names the offending value while the node still knows which script produced it.

  Everything else is `{:error, {reason, detail}}` — the shape
  `YmerNode.Scripts.Compiler` already uses, `reason` naming the rule and `detail`
  naming the script, the action and what happened:

  | reason | what it means |
  | --- | --- |
  | `:not_accepted` | the row's accepted hash is not its code hash |
  | `:not_loaded` | this node has no compiled module for the script |
  | `:unknown_action` | the script serves no action by that name |
  | `:invalid_schema` | the action's own `:properties` are not a schema `jsv` can build |
  | `:invalid_args` | the arguments do not satisfy that schema |
  | `:script_error` | the script answered `{:error, term}` |
  | `:script_raised` | the script raised; the detail carries its own line |
  | `:script_exited` | the run process exited for some other reason |
  | `:bad_return` | `run/3` answered neither `{:ok, _}` nor `{:error, _}` |
  | `:result_not_encodable` | the value does not encode to JSON |
  | `:timeout` | the deadline passed and the run was killed |

  `:script_error` carries the script's own term, with two exceptions. A run that
  hands back an unresolved secret — declared and unset, or asked for and never
  declared — is rendered by naming the secret and the verb that answers it,
  because the node is what knows the verb and the script is not. A throttle's
  refusal needs no exception of its own: it is a `YmerNode.Scripts.Throttle.Error`,
  whose message already names the throttle, what stopped the request and what
  answers it, and an exception is rendered by its message. Every other term is
  `inspect/1`'d as it came.
  """
  alias YmerNode.Script.Context
  alias YmerNode.Scripts.Loader
  alias YmerNode.Scripts.Script

  @registry YmerNode.Scripts.Runs
  @supervisor YmerNode.Scripts.TaskSupervisor

  @default_timeout 30_000
  @timeout_cap 300_000
  @metadata_timeout 5_000

  # How far behind its deadline a task kills itself when nobody is left to do
  # it. While the caller lives its own `Task.yield` answers first, so a live
  # caller never sees the backstop and a timeout never reads as an exit.
  @orphan_grace 1_000

  # `jsv` reports a container's failure beside the leaf failure inside it — a
  # `%{"n" => "no"}` against one typed property answers both `#/n value is not of
  # type integer` and `# property 'n' did not conform to the property schema`.
  # The second says nothing the first does not and points at no argument the
  # caller can fix, so only the leaves are rendered.
  @rollup_kinds [:properties, :items]

  # ─── Public API ─────────────────────────────────────────────────────

  @doc """
  Runs one action of one accepted script and answers what it produced.

  `action` arrives as a string from the wire and is matched against the names the
  script's `actions/0` reports — never converted with `String.to_atom/1`, which
  would let a caller fill the atom table one unknown action at a time.
  """
  def run(%Script{} = script, action, args) when is_binary(action) and is_map(args) do
    with :ok <- check_accepted(script) do
      registered(script, fn -> resolve_and_run(script, action, args) end)
    end
  end

  @doc """
  The deadline one action gets: its own `:timeout` where it names one, thirty
  seconds where it does not, and never past the five-minute cap.

  ## Examples

      iex> YmerNode.Scripts.Runner.deadline(%{properties: %{}, write: false})
      30000

      iex> YmerNode.Scripts.Runner.deadline(%{properties: %{}, write: false, timeout: 60_000})
      60000

      iex> YmerNode.Scripts.Runner.deadline(%{properties: %{}, write: false, timeout: 900_000})
      300000

  """
  def deadline(%{timeout: timeout}) when is_integer(timeout) and timeout > 0 do
    min(timeout, @timeout_cap)
  end

  def deadline(schema) when is_map(schema), do: @default_timeout

  @doc """
  Whether a run of this script is in flight right now — the question every door
  that replaces or removes a script's code asks before it lands.
  """
  def in_flight?(name) when is_binary(name), do: Registry.lookup(@registry, name) != []

  @doc """
  Checks one call the way a run would, without running it — whether the script
  is accepted and compiled, whether it serves the action, and whether the
  arguments satisfy that action's schema — and answers the schema.

  Read from this boot's compile (`YmerNode.Scripts.Loader.facts/1`) rather than
  from the script's own `actions/0`, so no script code runs: a door storing an
  instruction to run later can refuse now what the run would refuse then. Every
  refusal is one `run/3` gives.
  """
  def check(%Script{} = script, action, args) when is_binary(action) and is_map(args) do
    with :ok <- check_accepted(script),
         {:ok, facts} <- loaded(script),
         {:ok, name, schema} <- resolve_action(script, facts.actions, action),
         :ok <- check_args(script, name, schema, args) do
      {:ok, schema}
    end
  end

  @doc """
  The longest one run of an action can take before it answers — the metadata
  read's bound and then the action's deadline — so a caller starting a run now
  can say when it ends at the latest.

  ## Examples

      iex> YmerNode.Scripts.Runner.longest(%{properties: %{}, write: false})
      35000

  """
  def longest(schema) when is_map(schema), do: @metadata_timeout + deadline(schema)

  # ─── Before the run ─────────────────────────────────────────────────

  # One entry for the whole call, taken here and released whatever happens —
  # both bounded reads, and the argument check this process does between them.
  # It is taken BEFORE the loader is asked for a module, which is what lets the
  # loader refuse a purge on the strength of it: nothing else hands out a
  # script's module, so a run that got one registered first.
  # `unregister_match/3` and not `unregister/2`: the latter drops every entry
  # this process holds under the key, and a script that runs another action of
  # its own name from inside `run/3` would take the task's entry with it.
  defp registered(%Script{name: name}, fun) do
    Registry.register(@registry, name, :run)

    try do
      fun.()
    after
      Registry.unregister_match(@registry, name, :run)
    end
  end

  defp resolve_and_run(script, action, args) do
    with {:ok, module} <- loaded_module(script),
         {:ok, prepared} <- prepare(script, module, action, args) do
      execute(script, module, prepared)
    end
  end

  defp check_accepted(%Script{} = script) do
    if Script.accepted?(script) do
      :ok
    else
      {:error,
       {:not_accepted,
        "#{script.name} is not accepted at its current code — accept it before running it"}}
    end
  end

  defp loaded_module(%Script{} = script) do
    with {:ok, facts} <- loaded(script), do: {:ok, facts.module}
  end

  defp loaded(%Script{name: name}) do
    case Loader.facts(name) do
      %{loaded?: true} = facts -> {:ok, facts}
      %{error: {reason, detail}} -> {:error, {:not_loaded, "#{name}: #{reason} — #{detail}"}}
      nil -> {:error, {:not_loaded, "#{name} has not been compiled since this node started"}}
    end
  end

  defp prepare(script, module, action, args) do
    with {:ok, metadata} <- read_metadata(script, module),
         {:ok, name, schema} <- resolve_action(script, metadata.actions, action),
         :ok <- check_args(script, name, schema, args) do
      {:ok,
       %{
         action: name,
         args: args,
         secrets: metadata.secrets,
         throttles: metadata.throttles,
         timeout: deadline(schema)
       }}
    end
  end

  defp read_metadata(script, module) do
    in_task(script, "metadata", @metadata_timeout, fn ->
      declarations = module.declarations()

      %{
        actions: module.actions(),
        secrets: declarations.secrets,
        throttles: Map.get(declarations, :throttles, %{})
      }
    end)
  end

  defp resolve_action(script, actions, action) when is_map(actions) do
    case Enum.find(actions, fn {name, _schema} -> Atom.to_string(name) == action end) do
      {name, schema} ->
        {:ok, name, schema}

      nil ->
        {:error,
         {:unknown_action, "#{script.name} has no action #{action}; it serves #{served(actions)}"}}
    end
  end

  defp served(actions) do
    case actions |> Map.keys() |> Enum.sort() do
      [] -> "no actions at all"
      names -> Enum.map_join(names, ", ", &Atom.to_string/1)
    end
  end

  # ─── The arguments ──────────────────────────────────────────────────

  defp check_args(script, action, schema, args) do
    json_schema = %{
      "type" => "object",
      "properties" => Map.get(schema, :properties, %{}),
      "required" => Map.get(schema, :required, [])
    }

    case JSV.build(json_schema) do
      {:ok, root} -> validate_args(script, action, root, args)
      {:error, error} -> {:error, {:invalid_schema, detail(script, action, error)}}
    end
  end

  # The validated data is discarded and the caller's own `args` go to the
  # script: nothing here asks `jsv` to cast, so the two are the same map, and
  # handing the script the map it was called with keeps that plain.
  defp validate_args(script, action, root, args) do
    case JSV.validate(args, root) do
      {:ok, _validated} ->
        :ok

      {:error, error} ->
        {:error, {:invalid_args, "#{where(script, action)}: #{render_validation(error)}"}}
    end
  end

  defp render_validation(error) do
    error
    |> JSV.normalize_error()
    |> Map.fetch!(:details)
    |> Enum.flat_map(&detail_messages/1)
    |> Enum.join("; ")
  end

  defp detail_messages(%{instanceLocation: at, errors: errors}) do
    for %{kind: kind, message: message} <- errors,
        kind not in @rollup_kinds,
        do: "#{at} #{message}"
  end

  # ─── The run ────────────────────────────────────────────────────────

  defp execute(script, module, prepared) do
    %{action: action, args: args, timeout: timeout} = prepared

    context = %Context{
      script: script.name,
      action: action,
      secrets: prepared.secrets,
      throttles: prepared.throttles,
      deadline: System.monotonic_time(:millisecond) + timeout
    }

    label = Atom.to_string(action)

    case in_task(script, label, timeout, fn -> module.run(action, args, context) end) do
      {:ok, {:ok, value}} -> encodable(script, action, value)
      {:ok, {:error, reason}} -> {:error, {:script_error, script_error(script, action, reason)}}
      {:ok, other} -> {:error, {:bad_return, bad_return_text(script, action, other)}}
      {:error, _reason} = error -> error
    end
  end

  # A script's own error is rendered as it came, with two exceptions: the two a
  # script cannot render for itself, because the node is what knows the verb
  # that fixes them. `YmerNode.Script.Context` hangs the secret's NAME on both,
  # which is what these clauses need — a caller declaring several secrets must
  # not have to read the code to learn which one was missing.
  defp script_error(script, action, {:secret_not_found, secret}) do
    "#{where(script, action)}: no #{secret} secret is set on this machine — " <>
      "set it with `ymer-node secrets set #{secret}`"
  end

  defp script_error(script, action, {:secret_undeclared, secret}) do
    "#{where(script, action)}: the script asked for the secret #{secret}, which its " <>
      "declarations/0 does not name — declare it and accept the code again"
  end

  defp script_error(script, action, reason), do: detail(script, action, reason)

  defp in_task(script, label, timeout, fun) do
    name = script.name
    task = Task.Supervisor.async_nolink(@supervisor, fn -> backstopped(name, timeout, fun) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, value} ->
        {:ok, value}

      {:exit, {exception, stacktrace}} when is_exception(exception) and is_list(stacktrace) ->
        {:error, {:script_raised, raised_text(script, label, exception, stacktrace)}}

      {:exit, reason} ->
        {:error, {:script_exited, "#{script.name} #{label}: #{inspect(reason)}"}}

      nil ->
        {:error, {:timeout, "#{script.name} #{label}: no answer in #{timeout} ms, run killed"}}
    end
  end

  # The task's own half of the in-flight entry and of the deadline. The caller
  # holds both while it lives, but a caller can die mid-run — a client
  # cancelling, an rpc interrupted — and this task is not linked to it: without
  # an entry of its own the run would vanish from `in_flight?/1` while still
  # executing, and without a kill of its own it would run unbounded.
  #
  # Both are released here, before the answer is sent, and not left to the
  # registry's and the timer's own cleanup. The registry drops a dead process's
  # entry a moment AFTER `Task.yield` has handed the caller its value, so a
  # caller writing the script straight after running it would be refused
  # `run_in_flight` for a run that had answered; and a finished run's timer
  # would otherwise sit in the timer server for its whole deadline. A task the
  # timer killed never reaches this `after`, and there the registry's own
  # cleanup is the one that runs.
  defp backstopped(name, timeout, fun) do
    Registry.register(@registry, name, :task)
    {:ok, timer} = :timer.kill_after(timeout + @orphan_grace)

    try do
      fun.()
    after
      Registry.unregister_match(@registry, name, :task)
      :timer.cancel(timer)
    end
  end

  # ─── The answer ─────────────────────────────────────────────────────

  # `JSON.encode!/1` already finds the offending term and hangs it on the
  # exception — `Protocol.UndefinedError`'s `:value` is the innermost one, not
  # the container — so the node reads the value off the exception rather than
  # walking the term itself. Its rendered message is a screenful of `@derive`
  # advice aimed at whoever owns the struct, which is not this caller.
  defp encodable(script, action, value) do
    _json = JSON.encode!(value)
    {:ok, value}
  rescue
    error in Protocol.UndefinedError ->
      text = "#{where(script, action)}: #{inspect(error.value)} does not encode to JSON"
      {:error, {:result_not_encodable, text}}

    error ->
      {:error, {:result_not_encodable, detail(script, action, error)}}
  end

  defp raised_text(script, label, exception, stacktrace) do
    "#{script.name} #{label}: #{Exception.message(exception)}#{script_frame(stacktrace)}"
  end

  # The compiler names a script's file `script:<name>`, so the frame that
  # belongs to the script says so and every frame from the node's own code does
  # not. Showing the first one turns "boom" into "boom (script:hex:12: …)".
  defp script_frame(stacktrace) do
    case Enum.find(stacktrace, &script_frame?/1) do
      nil -> ""
      entry -> " (" <> Exception.format_stacktrace_entry(entry) <> ")"
    end
  end

  defp script_frame?({_module, _function, _arity, location}) when is_list(location) do
    location |> Keyword.get(:file, ~c"") |> List.to_string() |> String.starts_with?("script:")
  end

  defp script_frame?(_entry), do: false

  defp bad_return_text(script, action, other) do
    "#{where(script, action)}: run/3 must answer {:ok, term} or {:error, term}, got " <>
      inspect(other)
  end

  defp detail(script, action, term) when is_exception(term) do
    "#{where(script, action)}: #{Exception.message(term)}"
  end

  defp detail(script, action, term), do: "#{where(script, action)}: #{inspect(term)}"

  defp where(script, action), do: "#{script.name} #{action}"
end
