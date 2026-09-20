defmodule YmerNode.Scripts.Compiler do
  @moduledoc """
  Turns a script's code into a loaded module tree, or into a refusal that names
  what is wrong with it.

  ## The parse comes first, and nothing compiles until it passes

  A script's modules are VM-global. `defmodule Enum` in a script would replace
  the standard library's `Enum` for the whole node, and `defmodule
  YmerNode.Repo` would replace the node's own — for every process, immediately,
  with no way back short of a restart. So the code is **parsed** before it is
  compiled and refused unless every `defmodule` the parse can see sits under
  the script's own `Script.<Name>` subtree. `Code.string_to_quoted/2` runs no
  user code, so the refusal costs nothing.

  What it can see is syntax, and that is the limit to state plainly: an alias
  that rebinds `Script`, a `defmodule` wrapped in another form, a qualified
  `Kernel.defmodule/2` and a `Module.create/3` call in a module body are all
  outside it — and a module body runs while it compiles, so compiling code is
  running it whatever a parse saw. This guard catches the honest mistake before
  any compile; the boundary against a hostile author is which code is allowed
  to compile at all, which is `script_author`'s approval and acceptance
  (`YmerNode`'s Scripts section).

  Three shapes are refused there, and each was measured rather than reasoned
  about:

    * a top-level `defmodule` outside `Script.` — including bare `defmodule
      Script`, and a three-segment `Script.Jira.Client` as the top module;
    * a `defmodule Elixir.Anything` **anywhere**, nested included. This is the
      escape: nesting it inside `Script.Hex` does not scope it, and compiling
      that string really does define a top-level module;
    * a `defmodule` whose name is not a literal alias — `unquote(name)`,
      `@attribute`, `Module.concat(…)` — because a name computed at compile
      time is a name this check cannot read.

  The name is **derived**, never given: `Macro.underscore/1` over the top
  module's last segment, so the row's name, the VM module tree and the
  references source token are one identity and a unique name implies a unique
  tree.

  ## Compiling

  The previous tree is purged first. Recompiling a loaded module without purging
  is not an error — it is two `redefining module` **warnings** that would ride
  into the row's diagnostics and read as the script's fault.

  The compile file name is `script:<name>`, which is what makes a run's stack
  frames legible: a raise inside a script renders as `script:hex:3: Script.Hex.go/0`
  rather than naming a file nobody can open.

  ## The contract is checked here, not by the compiler

  A behaviour's missing callback is a **warning**. A script that `use`s
  `YmerNode.Script` and never defines `run/3` compiles, loads, and fails at the
  first call. So every callback is checked with `function_exported?/3` after the
  compile, and a module carrying no `__script_contract__/0` is refused as not
  having used the contract at all.

  The three metadata callbacks are then called — that is user code running
  inside a write — so the call is bounded by its own task and timeout. A
  `description/0` that loops would otherwise hang a `create`, and at boot it
  would hang the node's start.

  ## The compile itself is bounded too

  A `defmodule` body runs its top-level statements *while it compiles*, so
  `defmodule Script.Boom do Process.sleep(:infinity) end` — or an accidental
  loop written outside a function — never returns from
  `Code.compile_string/2`. `try/rescue` catches a raise and nothing else, so the
  compile gets its own task and its own deadline, and a compile that outstays it
  is killed and refused as `:compile_timeout`.

  The bound is separate from the metadata one and larger: a real module's
  compile-time work — deriving protocols, building a big literal — can
  legitimately take longer than three callbacks that must answer immediately.
  It matters more than a caller's patience: this call happens inside the one
  process that owns every compile, so a compile that never returned would wedge
  every later read and write, and at boot it would hang the node's start with no
  log line and no way in.
  """
  alias YmerNode.Script

  @compile_timeout 15_000
  @metadata_timeout 5_000

  # The runner's supervisor, started ahead of the loader (`YmerNode.Application`)
  # so the boot compile has it too.
  @supervisor YmerNode.Scripts.TaskSupervisor

  @doc """
  Reads a script's identity out of its code without compiling any of it.

  Answers `{:ok, %{name: name, module: module}}`, or `{:error, {reason, detail}}`
  where `reason` names the rule the code broke.
  """
  def parse(code) when is_binary(code) do
    with {:ok, ast} <- to_quoted(code),
         {:ok, top} <- top_module(ast),
         :ok <- check_every_defmodule(ast) do
      {:ok, %{name: derive_name(top), module: Module.concat(top)}}
    end
  end

  @doc """
  Parses, purges the previous tree, compiles, and reads the contract.

  On success answers `{:ok, map}` carrying `name`, `module`, every `modules`
  the code defined, the `contract` version, and the `description`, `actions` and
  `declarations` the module reports, plus any compile `warnings` as rendered
  strings. Every failure is `{:error, {reason, detail}}`.
  """
  def compile(code) when is_binary(code) do
    with {:ok, %{name: name, module: module}} <- parse(code) do
      purge(module)
      compile_parsed(code, name, module)
    end
  end

  @doc """
  Unloads a script's whole module tree — the top module and everything under it
  that is loaded right now.

  Scanning the loaded set rather than trusting a remembered list is deliberate:
  the list can be stale (a previous compile in this VM that nothing recorded),
  and a module left loaded is one a later compile would warn about redefining.
  """
  def purge(top_module) when is_atom(top_module) do
    prefix = Atom.to_string(top_module) <> "."

    for {module, _file} <- :code.all_loaded(),
        module == top_module or String.starts_with?(Atom.to_string(module), prefix) do
      :code.purge(module)
      :code.delete(module)
      module
    end
  end

  @doc """
  Renders compile diagnostics as one line each — `script:hex:3:5: message` —
  which is what `describe` shows and what a refusal carries.
  """
  def render_diagnostics(diagnostics) when is_list(diagnostics) do
    Enum.map(diagnostics, &render_diagnostic/1)
  end

  # ─── Parsing ────────────────────────────────────────────────────────

  defp to_quoted(code) do
    case Code.string_to_quoted(code) do
      {:ok, ast} ->
        {:ok, ast}

      {:error, {meta, message, token}} ->
        {:error, {:syntax_error, syntax_text(meta, message, token)}}
    end
  end

  defp syntax_text(meta, message, token) do
    line = if is_list(meta), do: Keyword.get(meta, :line), else: meta
    "line #{inspect(line)}: #{message_text(message)}#{token}"
  end

  defp message_text({prefix, suffix}), do: prefix <> suffix
  defp message_text(message) when is_binary(message), do: message

  defp top_module(ast) do
    case Enum.map(top_forms(ast), &defmodule_alias/1) do
      [] -> {:error, {:no_module, "the code defines no module"}}
      [{:ok, [:Script, name]}] when is_atom(name) -> {:ok, [:Script, name]}
      [{:ok, segments}] -> {:error, {:module_outside_script, render_segments(segments)}}
      [_dynamic] -> {:error, {:dynamic_module_name, "the top module's name is computed"}}
      several -> {:error, {:several_top_modules, render_several(several)}}
    end
  end

  defp top_forms({:__block__, _meta, forms}), do: Enum.filter(forms, &defmodule?/1)
  defp top_forms(nil), do: []
  defp top_forms(form), do: Enum.filter([form], &defmodule?/1)

  defp defmodule?({:defmodule, _meta, [_name | _rest]}), do: true
  defp defmodule?(_form), do: false

  defp defmodule_alias({:defmodule, _meta, [{:__aliases__, _alias_meta, segments} | _rest]}),
    do: {:ok, segments}

  defp defmodule_alias({:defmodule, _meta, _args}), do: :dynamic

  # Every `defmodule` in the tree, not only the top one: a nested
  # `defmodule Elixir.Enum` is not scoped by its parent and really does define a
  # top-level module.
  defp check_every_defmodule(ast) do
    {_ast, offenders} = Macro.prewalk(ast, [], &collect_offender/2)

    case Enum.reverse(offenders) do
      [] -> :ok
      [first | _rest] -> first
    end
  end

  defp collect_offender({:defmodule, _meta, [first | _rest]} = node, acc) do
    {node, prepend_offender(first, acc)}
  end

  defp collect_offender(node, acc), do: {node, acc}

  defp prepend_offender({:__aliases__, _meta, segments}, acc) do
    cond do
      not Enum.all?(segments, &is_atom/1) ->
        [{:error, {:dynamic_module_name, "a module name is computed"}} | acc]

      hd(segments) == Elixir ->
        [{:error, {:module_outside_script, render_segments(segments)}} | acc]

      true ->
        acc
    end
  end

  defp prepend_offender(_other, acc),
    do: [{:error, {:dynamic_module_name, "a module name is computed"}} | acc]

  defp render_segments([Elixir | rest]), do: "Elixir." <> render_segments(rest)
  defp render_segments(segments), do: Enum.map_join(segments, ".", &Atom.to_string/1)

  defp render_several(entries) do
    Enum.map_join(entries, ", ", fn
      {:ok, segments} -> render_segments(segments)
      :dynamic -> "(computed)"
    end)
  end

  defp derive_name([:Script, name]), do: name |> Atom.to_string() |> Macro.underscore()

  # ─── Compiling ──────────────────────────────────────────────────────

  # In a task, because a module body's top-level statements run during the
  # compile: a `Process.sleep/1` or a loop written outside a function never
  # returns, and `try/rescue` sees a raise but not a call that does not come
  # back. `Code.with_diagnostics/1` collects the diagnostics of the process it
  # runs in, so it goes inside the task with the compile it is watching.
  #
  # Not linked to this process, deliberately. A body can end the task by an
  # exit SIGNAL — `spawn_link(fn -> exit(:boom) end)`, a started process whose
  # `init/1` stops — which no `try` inside the task can catch; linked, that
  # signal would reach the caller, which is `YmerNode.Scripts.Loader` holding
  # every script's facts, and at boot its `init/1`. Under the supervisor the
  # task's death arrives at `Task.yield` as `{:exit, reason}` and is refused
  # like any other failure.
  defp compile_parsed(code, name, module) do
    task = Task.Supervisor.async_nolink(@supervisor, fn -> compile_now(code, name) end)

    case Task.yield(task, @compile_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {{:ok, compiled}, diagnostics}} ->
        loaded(name, module, compiled, diagnostics)

      {:ok, {{:error, message}, diagnostics}} ->
        {:error, {:compile_error, compile_text(message, diagnostics)}}

      {:exit, reason} ->
        {:error, {:compile_error, "the compile exited: #{inspect(reason)}"}}

      nil ->
        {:error, {:compile_timeout, "no answer in #{@compile_timeout} ms"}}
    end
  end

  defp compile_now(code, name) do
    Code.with_diagnostics(fn ->
      try do
        {:ok, Code.compile_string(code, "script:" <> name)}
      rescue
        exception -> {:error, Exception.message(exception)}
      catch
        # A throw, or an exit the body makes itself, answered as a refusal
        # with the diagnostics still collected — cheaper and more telling than
        # letting the task die and reading its exit reason. An exit arriving
        # over a link is not catchable here; that is what the unlinked start
        # above is for. Same pair `metadata/0` carries.
        kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
      end
    end)
  end

  defp compile_text(message, diagnostics) do
    Enum.join([message | render_diagnostics(diagnostics)], "\n")
  end

  defp loaded(name, module, compiled, diagnostics) do
    modules = Enum.map(compiled, &elem(&1, 0))

    with :ok <- check_contract(module),
         :ok <- check_callbacks(module),
         {:ok, metadata} <- read_metadata(module),
         {:ok, declarations} <- normalise_declarations(metadata.declarations),
         :ok <- check_description(metadata.description),
         :ok <- check_actions(metadata.actions, declarations) do
      {:ok,
       %{
         name: name,
         module: module,
         modules: modules,
         contract: module.__script_contract__(),
         description: metadata.description,
         actions: metadata.actions,
         declarations: declarations,
         warnings: render_diagnostics(diagnostics)
       }}
    end
  end

  defp check_contract(module) do
    cond do
      not function_exported?(module, :__script_contract__, 0) ->
        {:error, {:missing_contract, "the code does not `use YmerNode.Script`"}}

      module.__script_contract__() != Script.contract() ->
        {:error,
         {:unknown_contract,
          "this node speaks contract #{Script.contract()}; the code is written " <>
            "against #{inspect(module.__script_contract__())}"}}

      true ->
        :ok
    end
  end

  defp check_callbacks(module) do
    case Enum.reject(Script.callbacks(), fn {name, arity} ->
           function_exported?(module, name, arity)
         end) do
      [] ->
        :ok

      missing ->
        {:error,
         {:missing_callbacks, Enum.map_join(missing, ", ", &"#{elem(&1, 0)}/#{elem(&1, 1)}")}}
    end
  end

  # User code, inside a write. Bounded, because a `description/0` that loops
  # would hang a create — and at boot it would hang the node's start.
  defp read_metadata(module) do
    task = Task.Supervisor.async_nolink(@supervisor, fn -> metadata(module) end)

    case Task.yield(task, @metadata_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, metadata}} -> {:ok, metadata}
      {:ok, {:error, message}} -> {:error, {:metadata_raised, message}}
      {:exit, reason} -> {:error, {:metadata_raised, "exited: #{inspect(reason)}"}}
      nil -> {:error, {:metadata_timeout, "no answer in #{@metadata_timeout} ms"}}
    end
  end

  defp metadata(module) do
    {:ok,
     %{
       description: module.description(),
       actions: module.actions(),
       declarations: module.declarations()
     }}
  rescue
    exception -> {:error, Exception.message(exception)}
  catch
    kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
  end

  # ─── The contract's values ──────────────────────────────────────────

  defp check_description(description) when is_binary(description) do
    if String.trim(description) == "",
      do: {:error, {:invalid_description, "description/0 answers an empty string"}},
      else: :ok
  end

  defp check_description(other),
    do: {:error, {:invalid_description, "description/0 answers #{inspect(other)}, not a string"}}

  defp check_actions(actions, _declarations) when not is_map(actions),
    do: {:error, {:invalid_actions, "actions/0 answers #{inspect(actions)}, not a map"}}

  defp check_actions(actions, _declarations) when map_size(actions) == 0 do
    {:error, {:invalid_actions, "actions/0 answers an empty map"}}
  end

  defp check_actions(actions, declarations) do
    with :ok <- Enum.reduce_while(actions, :ok, &check_action/2) do
      check_url_action(declarations, actions)
    end
  end

  defp check_action({name, schema}, :ok) when is_atom(name) and is_map(schema) do
    case action_fault(name, schema) do
      nil -> {:cont, :ok}
      fault -> {:halt, {:error, {:invalid_actions, fault}}}
    end
  end

  defp check_action({name, _schema}, :ok),
    do:
      {:halt,
       {:error,
        {:invalid_actions, "action #{inspect(name)} is not an atom key with a map schema"}}}

  defp action_fault(name, schema) do
    cond do
      not is_binary(Map.get(schema, :description)) ->
        "action #{name}: :description must be a string"

      String.contains?(schema.description, "\n") ->
        "action #{name}: :description must not contain a newline"

      not is_map(Map.get(schema, :properties)) ->
        "action #{name}: :properties must be a map"

      not is_boolean(Map.get(schema, :write)) ->
        "action #{name}: :write must be true or false"

      true ->
        required_fault(name, schema)
    end
  end

  defp required_fault(name, schema) do
    required = Map.get(schema, :required, [])

    cond do
      not (is_list(required) and Enum.all?(required, &is_binary/1)) ->
        "action #{name}: :required must be a list of strings"

      Enum.any?(required, &(not Map.has_key?(schema.properties, &1))) ->
        "action #{name}: :required names a property :properties does not declare"

      true ->
        timeout_fault(name, schema)
    end
  end

  defp timeout_fault(name, schema) do
    case Map.get(schema, :timeout) do
      nil -> nil
      timeout when is_integer(timeout) and timeout > 0 -> nil
      other -> "action #{name}: :timeout must be a positive integer, got #{inspect(other)}"
    end
  end

  # ─── Declarations ───────────────────────────────────────────────────

  defp normalise_declarations(%{hosts: hosts, url_action: url_action, secrets: secrets} = given)
       when is_list(hosts) and is_list(secrets) and (is_atom(url_action) or is_nil(url_action)) do
    with :ok <- check_strings(hosts, ":hosts must be a list of strings"),
         :ok <- check_strings(secrets, ":secrets must be a list of strings"),
         {:ok, throttles} <- normalise_throttles(Map.get(given, :throttles, %{})) do
      {:ok,
       %{
         hosts: Enum.map(hosts, &String.downcase/1),
         url_action: url_action,
         secrets: secrets,
         throttles: throttles
       }}
    end
  end

  defp normalise_declarations(other) do
    {:error,
     {:invalid_declarations,
      "declarations/0 must answer %{hosts: [...], url_action: atom | nil, secrets: [...]}, " <>
        "got #{inspect(other)}"}}
  end

  defp check_strings(values, rule) do
    if Enum.all?(values, &is_binary/1), do: :ok, else: {:error, {:invalid_declarations, rule}}
  end

  # A throttle's name is the node's, shared by every script declaring it, and its
  # parameters are the account's, so both are checked here, at the compile.
  # Inside one throttle a key nobody reads is a typo and is refused, where the
  # outer declarations map stays open to keys a later node reads.
  defp normalise_throttles(throttles) when is_map(throttles) and not is_struct(throttles) do
    case Enum.find_value(throttles, &throttle_fault/1) do
      nil -> {:ok, throttles}
      fault -> {:error, {:invalid_declarations, fault}}
    end
  end

  defp normalise_throttles(other) do
    {:error,
     {:invalid_declarations,
      ":throttles must be a map from a throttle's name to its parameters, " <>
        "got #{inspect(other)}"}}
  end

  defp throttle_fault({name, parameters}) do
    cond do
      not (is_binary(name) and Regex.match?(~r/\A[a-z0-9][a-z0-9_-]*\z/, name)) ->
        "throttle name #{inspect(name)} must be a string of lowercase letters, digits, " <>
          "`-` and `_`, starting with a letter or a digit"

      not is_map(parameters) ->
        "throttle #{name}: its parameters must be a map, got #{inspect(parameters)}"

      true ->
        unknown_fault(name, parameters, [:rate, :burst, :breaker]) ||
          positive_fault(name, parameters, :rate, "requests per minute") ||
          positive_fault(name, parameters, :burst, "the most requests at once") ||
          breaker_fault(name, Map.fetch(parameters, :breaker))
    end
  end

  defp unknown_fault(name, map, known) do
    case Map.keys(map) -- known do
      [] ->
        nil

      [key | _rest] ->
        "throttle #{name}: #{inspect(key)} is not a key it reads — it reads " <>
          Enum.map_join(known, ", ", &inspect/1)
    end
  end

  defp positive_fault(name, map, key, unit) do
    case Map.fetch(map, key) do
      {:ok, value} when is_integer(value) and value > 0 ->
        nil

      {:ok, value} ->
        "throttle #{name}: #{inspect(key)} must be a positive integer, #{unit}, " <>
          "got #{inspect(value)}"

      :error ->
        "throttle #{name}: #{inspect(key)} is required — a positive integer, #{unit}"
    end
  end

  defp breaker_fault(_name, :error), do: nil

  defp breaker_fault(name, {:ok, breaker}) when is_map(breaker) do
    unknown_fault(name, breaker, [:threshold, :cooldown]) ||
      positive_fault(name, breaker, :threshold, "consecutive 401s") ||
      positive_fault(name, breaker, :cooldown, "milliseconds")
  end

  defp breaker_fault(name, {:ok, other}),
    do:
      "throttle #{name}: :breaker must be a map of :threshold and :cooldown, got #{inspect(other)}"

  # A host claim with no action to run is a claim on nothing; an action that
  # takes no `url` cannot be handed a reference's uri. Both are refused here
  # rather than at acceptance, because both are facts about the code alone.
  defp check_url_action(%{url_action: nil, hosts: []}, _actions), do: :ok

  defp check_url_action(%{url_action: nil, hosts: [_ | _]}, _actions),
    do: {:error, {:invalid_declarations, ":hosts claims a host while :url_action is nil"}}

  defp check_url_action(%{url_action: url_action}, actions) do
    case Map.fetch(actions, url_action) do
      :error ->
        {:error,
         {:invalid_declarations,
          ":url_action names #{url_action}, which actions/0 does not declare"}}

      {:ok, schema} ->
        if Map.has_key?(schema.properties, "url"),
          do: :ok,
          else:
            {:error, {:invalid_declarations, "action #{url_action} declares no `url` property"}}
    end
  end

  defp render_diagnostic(%{message: message} = diagnostic) do
    file = Map.get(diagnostic, :file) || "script"
    "#{file}#{position(Map.get(diagnostic, :position))}: #{message}"
  end

  defp position({line, column}), do: ":#{line}:#{column}"
  defp position(line) when is_integer(line), do: ":#{line}"
  defp position(_absent), do: ""
end
