defmodule YmerNode.Scripts.Compiler do
  @moduledoc """
  Turns a script's or a library's code into a loaded module tree, or into a
  refusal that names what is wrong with it.

  ## The parse comes first, and nothing compiles until it passes

  A script's modules are VM-global. `defmodule Enum` in a script would replace
  the standard library's `Enum` for the whole node, and `defmodule
  YmerNode.Repo` would replace the node's own — for every process, immediately,
  with no way back short of a restart. So the code is **parsed** before it is
  compiled and refused unless every `defmodule` the parse can see sits under
  the code's own `Script.<Name>` subtree — a library's, under `Library.<Name>`.
  `Code.string_to_quoted/2` runs no user code, so the refusal costs nothing.

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

    * a top-level `defmodule` outside `Script.` and `Library.` — including bare
      `defmodule Script`, and a three-segment `Script.Jira.Client` as the top
      module;
    * a `defmodule Elixir.Anything` **anywhere**, nested included. This is the
      escape: nesting it inside `Script.Hex` does not scope it, and compiling
      that string really does define a top-level module;
    * a `defmodule` whose name is not a literal alias — `unquote(name)`,
      `@attribute`, `Module.concat(…)` — because a name computed at compile
      time is a name this check cannot read.

  The name is **derived**, never given: `Macro.underscore/1` over the top
  module's last segment, so the row's name, the VM module tree and the
  references source token are one identity and a unique name implies a unique
  tree. The top module's first segment is the **kind**: `Script.Hex` is the
  script `hex`, `Library.Crosskey` the library `crosskey`. The two trees never
  overlap under `purge/1`'s prefix rule, and the two kinds share one name space
  in the `scripts` table, so `Script.Crosskey` and `Library.Crosskey` cannot
  both be held.

  ## A library the code names is a library it declares

  The parse also collects every `Library.<Name>` alias the code writes — in a
  call, an `alias`, an `import` or a `require` — because a call the node does
  not know about escapes everything it keeps true about libraries: the order
  boot compiles them in, the refusal to remove one a script still uses, and
  `describe`'s list of what a script calls. A library naming any library but
  itself is refused here, at the parse. A script's names are compared with the
  `libraries` of its declarations once `declarations/0` has answered, inside
  this same compile and before anything is stored; a `require` or an `import`
  of a library this node does not hold fails the compile itself before that
  comparison is reached, so such a script is refused, or kept Broken at boot,
  with the compiler's error rather than the library refusal. `Elixir.Library.X`
  is read as `Library.X`, and `Library` written alone — `alias Library, as: L`
  — is refused, since every call through it would reach a library no name here
  records. The limit is the `defmodule` rule's: syntax only, so a name built at
  run time with `Module.concat/2`, or written as an atom literal
  (`:"Elixir.Library.X"`), passes. The names are compared, not the modules:
  `Library.JiraAPI` and `Library.JiraApi` both derive to `jira_api`, so a script
  writing the one while the node holds the other is accepted and fails at its
  call with `UndefinedFunctionError`.

  ## Compiling

  The previous tree is purged first. Recompiling a loaded module without purging
  is not an error — it is two `redefining module` **warnings** that would ride
  into the row's diagnostics and read as the script's fault.

  The compile file name is `script:<name>`, or `library:<name>`, which is what
  makes a run's stack frames legible: a raise inside a script renders as
  `script:hex:3: Script.Hex.go/0` rather than naming a file nobody can open.

  ## The contract is checked here, not by the compiler

  A behaviour's missing callback is a **warning**. A script that `use`s
  `YmerNode.Script` and never defines `run/3` compiles, loads, and fails at the
  first call. So every callback is checked with `function_exported?/3` after the
  compile, and a module carrying no `__script_contract__/0` is refused as not
  having used the contract at all. A library is checked against
  `YmerNode.Library` the same way, and each contract is refused under the other
  kind's namespace.

  The metadata callbacks are then called — that is user code running inside a
  write — so the call is bounded by its own task and timeout. A
  `description/0` that loops would otherwise hang a `create`, and at boot it
  would hang the node's start. `version/0` must answer a version `Version`
  parses.

  A library's API is read from the compiled binaries' `Docs` chunks, which
  `Code.compile_string/2` keeps although `Code.fetch_docs/1` cannot reach them
  for a module with no file: each function with a `@doc`, by its signature and
  its text, is what `describe` shows a script's author in place of the code.

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
  alias YmerNode.Library
  alias YmerNode.Script

  @compile_timeout 15_000
  @metadata_timeout 5_000

  # Every key a declaration may carry. A key outside them is refused by name
  # rather than dropped: a node that dropped a key it does not read would run a
  # script written for a newer node without the thing that key asked for.
  @declaration_keys [:hosts, :url_action, :secrets, :throttles, :cache, :web_fallback, :libraries]

  # The runner's supervisor, started ahead of the loader (`YmerNode.Application`)
  # so the boot compile has it too.
  @supervisor YmerNode.Scripts.TaskSupervisor

  @doc """
  Reads a script's or a library's identity out of its code without compiling
  any of it.

  Answers `{:ok, %{name: name, module: module, kind: kind, libraries: named}}` —
  `kind` is `:script` or `:library`, and `named` maps each library the code
  names to the alias it wrote, `%{"crosskey" => "Library.Crosskey"}` — or
  `{:error, {reason, detail}}` where `reason` names the rule the code broke.
  """
  def parse(code) when is_binary(code) do
    with {:ok, ast} <- to_quoted(code),
         {:ok, top} <- top_module(ast),
         :ok <- check_every_defmodule(ast),
         {:ok, named} <- named_libraries(ast, top) do
      {:ok,
       %{name: derive_name(top), module: Module.concat(top), kind: kind(top), libraries: named}}
    end
  end

  @doc """
  Parses, purges the previous tree, compiles, and reads the contract.

  On success answers `{:ok, map}` carrying `name`, `module`, `kind`, every
  `modules` the code defined, the `contract` version, the `description` and
  `version` the module reports, and any compile `warnings` as rendered strings.
  A script's map carries its `actions` and `declarations` and an `api` of `nil`;
  a library's carries no actions, `declarations: nil`, and its `api`: each
  documented function as `%{name: name, signature: signature, doc: text}`.
  Every failure is `{:error, {reason, detail}}`, and leaves no tree loaded: a
  refusal after the modules loaded purges them before it answers.
  """
  def compile(code) when is_binary(code) do
    with {:ok, parsed} <- parse(code) do
      purge(parsed.module)
      compile_parsed(code, parsed)
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
      [{:ok, [:Library, name]}] when is_atom(name) -> {:ok, [:Library, name]}
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

  defp derive_name([_kind, name]), do: segment_name(name)

  defp segment_name(segment), do: segment |> Atom.to_string() |> Macro.underscore()

  defp kind([:Script, _name]), do: :script
  defp kind([:Library, _name]), do: :library

  # Every library the code names, by name, with the alias as it was written. A
  # library's own tree is itself, and any other library it names is refused
  # here; a script's names wait for its declarations (`check_declared/2`).
  defp named_libraries(ast, top) do
    {_ast, named} = Macro.prewalk(ast, %{}, &collect_library/2)

    cond do
      Map.has_key?(named, :bare) ->
        {:error,
         {:undeclared_library,
          "the code writes Library alone, which hides the library each call reaches — " <>
            "alias each library in full: alias Library.Crosskey"}}

      kind(top) == :script ->
        {:ok, named}

      true ->
        refuse_other_library(Map.delete(named, derive_name(top)))
    end
  end

  defp refuse_other_library(named) when map_size(named) == 0, do: {:ok, %{}}

  defp refuse_other_library(named) do
    {_name, written} = Enum.min(named)

    {:error,
     {:undeclared_library,
      "#{written} is another library, and a library names no other: move the shared " <>
        "code into this one, or call #{written} from the script instead"}}
  end

  defp collect_library({:__aliases__, _meta, [:Library, segment | _rest]} = node, named)
       when is_atom(segment) do
    {node, Map.put_new(named, segment_name(segment), "Library.#{segment}")}
  end

  # `Elixir.Library.Crosskey` is the same alias written in full.
  defp collect_library({:__aliases__, meta, [Elixir, :Library, segment | rest]}, named)
       when is_atom(segment),
       do: collect_library({:__aliases__, meta, [:Library, segment | rest]}, named)

  # `alias Library.{Crosskey, Jira}` names each library inside the braces. The
  # node is answered as an empty block, so the walk does not descend into the
  # braces' bare `Library` head, which is no call of its own.
  defp collect_library(
         {{:., _dot, [{:__aliases__, _meta, [:Library]}, :{}]}, _call, children},
         named
       ) do
    {{:__block__, [], []}, Enum.reduce(children, named, &collect_child/2)}
  end

  # `Library` alone — `alias Library, as: L`, say — would let every call made
  # through it reach a library no name here records.
  defp collect_library({:__aliases__, _meta, [Elixir, :Library]} = node, named),
    do: {node, Map.put(named, :bare, "Library")}

  defp collect_library({:__aliases__, _meta, [:Library]} = node, named),
    do: {node, Map.put(named, :bare, "Library")}

  defp collect_library(node, named), do: {node, named}

  defp collect_child({:__aliases__, _meta, [segment | _rest]}, named) when is_atom(segment),
    do: Map.put_new(named, segment_name(segment), "Library.#{segment}")

  defp collect_child(_child, named), do: named

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
  defp compile_parsed(code, parsed) do
    file = "#{parsed.kind}:#{parsed.name}"
    task = Task.Supervisor.async_nolink(@supervisor, fn -> compile_now(code, file) end)

    case compile_outcome(parsed, task) do
      {:ok, _compiled} = accepted ->
        accepted

      # A refusal after the tree loaded — a missing callback, a bad version, a
      # declaration — or a compile that died half way leaves modules behind;
      # they go with the refusal, so a refused tree is never callable.
      refused ->
        purge(parsed.module)
        refused
    end
  end

  defp compile_outcome(parsed, task) do
    case Task.yield(task, @compile_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {{:ok, compiled}, diagnostics}} ->
        loaded(parsed, compiled, diagnostics)

      {:ok, {{:error, message}, diagnostics}} ->
        {:error, {:compile_error, compile_text(message, diagnostics)}}

      {:exit, reason} ->
        {:error, {:compile_error, "the compile exited: #{inspect(reason)}"}}

      nil ->
        {:error, {:compile_timeout, "no answer in #{@compile_timeout} ms"}}
    end
  end

  # Docs are switched on before every compile and never back off: a library's
  # API is its `Docs` chunk, and `mix test` turns the option off for its whole
  # run. A release and `mix run` already have it on, so there it changes nothing;
  # every caller sets the same value, so concurrent compiles cannot race on it.
  defp compile_now(code, file) do
    Code.put_compiler_option(:docs, true)

    Code.with_diagnostics(fn ->
      try do
        {:ok, Code.compile_string(code, file)}
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

  defp loaded(parsed, compiled, diagnostics) do
    %{module: module, kind: kind} = parsed

    with :ok <- check_contract(module, kind),
         :ok <- check_callbacks(module, kind),
         {:ok, metadata} <- read_metadata(module, kind),
         :ok <- check_description(metadata.description),
         :ok <- check_version(metadata.version),
         {:ok, shape} <- shape(kind, parsed, metadata, compiled) do
      {:ok,
       Map.merge(shape, %{
         name: parsed.name,
         module: module,
         kind: kind,
         modules: Enum.map(compiled, &elem(&1, 0)),
         contract: apply(module, contract_function(kind), []),
         description: metadata.description,
         version: metadata.version,
         warnings: render_diagnostics(diagnostics)
       })}
    end
  end

  # What only a script carries — its actions and its declarations, each checked —
  # and what only a library does: the API its documented functions make.
  defp shape(:script, parsed, metadata, _compiled) do
    with {:ok, declarations} <- normalise_declarations(metadata.declarations),
         :ok <- check_actions(metadata.actions, declarations),
         :ok <- check_declared(parsed.libraries, declarations.libraries) do
      {:ok, %{actions: metadata.actions, declarations: declarations, api: nil}}
    end
  end

  defp shape(:library, _parsed, _metadata, compiled),
    do: {:ok, %{actions: %{}, declarations: nil, api: api(compiled)}}

  defp contract_module(:script), do: Script
  defp contract_module(:library), do: Library

  defp contract_function(:script), do: :__script_contract__
  defp contract_function(:library), do: :__library_contract__

  defp check_contract(module, kind) do
    own = contract_function(kind)
    contract = contract_module(kind)

    cond do
      function_exported?(module, contract_function(other_kind(kind)), 0) ->
        {:error, {:contract_mismatch, mismatch_text(module, kind)}}

      not function_exported?(module, own, 0) ->
        {:error, {:missing_contract, "the code does not `use #{inspect(contract)}`"}}

      apply(module, own, []) != contract.contract() ->
        {:error,
         {:unknown_contract,
          "this node speaks #{kind} contract #{contract.contract()}; the code is written " <>
            "against #{inspect(apply(module, own, []))}"}}

      true ->
        :ok
    end
  end

  defp other_kind(:script), do: :library
  defp other_kind(:library), do: :script

  defp mismatch_text(module, :script) do
    "#{inspect(module)} uses YmerNode.Library under `Script.` — a library sits under " <>
      "`Library.`, and a script uses YmerNode.Script"
  end

  defp mismatch_text(module, :library) do
    "#{inspect(module)} uses YmerNode.Script under `Library.` — a script sits under " <>
      "`Script.`, and a library uses YmerNode.Library"
  end

  # The fix rides the detail, because a row that stopped compiling after an
  # upgrade shows it at boot and in `describe`, where no tool adds one.
  defp check_callbacks(module, kind) do
    case Enum.reject(contract_module(kind).callbacks(), fn {name, arity} ->
           function_exported?(module, name, arity)
         end) do
      [] ->
        :ok

      missing ->
        {:error,
         {:missing_callbacks,
          Enum.map_join(missing, ", ", &"#{elem(&1, 0)}/#{elem(&1, 1)}") <>
            " — add #{if match?([_], missing), do: "it", else: "them"}, then store the " <>
            "code with `create` if it is new, or again with `update` or `scripts import`"}}
    end
  end

  # User code, inside a write. Bounded, because a `description/0` that loops
  # would hang a create — and at boot it would hang the node's start.
  defp read_metadata(module, kind) do
    task = Task.Supervisor.async_nolink(@supervisor, fn -> metadata(module, kind) end)

    case Task.yield(task, @metadata_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, metadata}} -> {:ok, metadata}
      {:ok, {:error, message}} -> {:error, {:metadata_raised, message}}
      {:exit, reason} -> {:error, {:metadata_raised, "exited: #{inspect(reason)}"}}
      nil -> {:error, {:metadata_timeout, "no answer in #{@metadata_timeout} ms"}}
    end
  end

  defp metadata(module, :script) do
    {:ok,
     %{
       description: module.description(),
       version: module.version(),
       actions: module.actions(),
       declarations: module.declarations()
     }}
  rescue
    exception -> {:error, Exception.message(exception)}
  catch
    kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
  end

  defp metadata(module, :library) do
    {:ok, %{description: module.description(), version: module.version()}}
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

  defp check_version(version) when is_binary(version) do
    case Version.parse(version) do
      {:ok, _version} ->
        :ok

      :error ->
        {:error,
         {:invalid_version,
          "version/0 answers #{inspect(version)}, which is not a version — write one " <>
            ~s|the way Elixir's Version reads it, "1.0.0"|}}
    end
  end

  defp check_version(other),
    do: {:error, {:invalid_version, "version/0 answers #{inspect(other)}, not a string"}}

  # Each library the code names must be one the declarations name, so that what
  # the node keeps true about a script's libraries covers every one it calls.
  defp check_declared(named, declared) do
    case named |> Map.drop(Map.keys(declared)) |> Enum.sort() do
      [] ->
        :ok

      [{name, written} | _rest] ->
        {:error,
         {:undeclared_library,
          "the code names #{written}, which declarations/0 does not declare — add " <>
            ~s|#{inspect(name)} to :libraries with a requirement, "~> 1.0" say|}}
    end
  end

  # Every public function or macro the library documents, in every module it
  # defines, read from the binaries' `Docs` chunks. A binary without one — a
  # build compiling without docs — answers what it has, which may be nothing.
  defp api(compiled) do
    compiled
    |> Enum.flat_map(fn {module, binary} -> documented(module, binary) end)
    |> Enum.sort_by(& &1.name)
  end

  defp documented(module, binary) do
    case :beam_lib.chunks(binary, [~c"Docs"]) do
      {:ok, {^module, [{~c"Docs", chunk}]}} ->
        {:docs_v1, _anno, _language, _format, _moduledoc, _meta, docs} =
          :erlang.binary_to_term(chunk)

        for {{kind, name, arity}, _anno, signature, %{"en" => text}, _meta} <- docs,
            kind in [:function, :macro] do
          %{
            name: "#{inspect(module)}.#{name}/#{arity}",
            signature: Enum.join(signature, " "),
            doc: text
          }
        end

      _no_docs ->
        []
    end
  end

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
    with :ok <- check_known_keys(given),
         :ok <- check_strings(hosts, ":hosts must be a list of strings"),
         :ok <- check_strings(secrets, ":secrets must be a list of strings"),
         {:ok, throttles} <- normalise_throttles(Map.get(given, :throttles, %{})),
         {:ok, cache} <- normalise_cache(Map.get(given, :cache, :text)),
         {:ok, web_fallback} <- normalise_web_fallback(Map.get(given, :web_fallback, false)),
         {:ok, libraries} <- normalise_libraries(Map.get(given, :libraries, %{})) do
      {:ok,
       %{
         hosts: Enum.map(hosts, &String.downcase/1),
         url_action: url_action,
         secrets: secrets,
         throttles: throttles,
         cache: cache,
         web_fallback: web_fallback,
         libraries: libraries
       }}
    end
  end

  defp normalise_declarations(other) do
    {:error,
     {:invalid_declarations,
      "declarations/0 must answer %{hosts: [...], url_action: atom | nil, secrets: [...]}, " <>
        "got #{inspect(other)}"}}
  end

  # Where the cache keeps what the URL action answers, and whether the script
  # serves the `web` source's unclaimed hosts. A script that names neither
  # stores text and backs no source, so every script written before either key
  # existed keeps the meaning it had.
  defp normalise_cache(cache) when cache in [:text, :file], do: {:ok, cache}

  defp normalise_cache(other),
    do: {:error, {:invalid_declarations, ":cache must be :text or :file, got #{inspect(other)}"}}

  defp normalise_web_fallback(web_fallback) when is_boolean(web_fallback), do: {:ok, web_fallback}

  defp normalise_web_fallback(other) do
    {:error,
     {:invalid_declarations, ":web_fallback must be true or false, got #{inspect(other)}"}}
  end

  defp check_known_keys(given) do
    case Map.keys(given) -- @declaration_keys do
      [] ->
        :ok

      [key | _rest] ->
        {:error,
         {:invalid_declarations,
          "#{inspect(key)} is not a declaration this node reads — it reads " <>
            Enum.map_join(@declaration_keys, ", ", &inspect/1)}}
    end
  end

  # The libraries a script calls, each by the name `list` shows it under, with
  # the range of versions the script was written against. Every entry states
  # one: `">= 0.0.0"` is how a script says any version will do.
  defp normalise_libraries(libraries) when is_map(libraries) and not is_struct(libraries) do
    case Enum.find_value(libraries, &library_fault/1) do
      nil -> {:ok, libraries}
      fault -> {:error, {:invalid_declarations, fault}}
    end
  end

  defp normalise_libraries(other) do
    {:error,
     {:invalid_declarations,
      ":libraries must be a map from a library's name to a requirement, got #{inspect(other)}"}}
  end

  defp library_fault({name, requirement}) do
    cond do
      not (is_binary(name) and Regex.match?(~r/\A[a-z][a-z0-9_]*\z/, name)) ->
        "library name #{inspect(name)} must be a library's name as `list` shows it: " <>
          "lowercase letters, digits and `_`, starting with a letter"

      not (is_binary(requirement) and match?({:ok, _}, Version.parse_requirement(requirement))) ->
        "library #{name}: #{inspect(requirement)} is not a requirement — write one the way " <>
          ~s|Elixir's Version reads it, "~> 1.0", or ">= 0.0.0" for any version|

      true ->
        nil
    end
  end

  defp check_strings(values, rule) do
    if Enum.all?(values, &is_binary/1), do: :ok, else: {:error, {:invalid_declarations, rule}}
  end

  # A throttle's name is the node's, shared by every script declaring it, and its
  # parameters are the account's, so both are checked here, at the compile.
  # Inside one throttle a key nobody reads is a typo and is refused, as a key the
  # declarations map itself does not know is.
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

  # A host claim with no action to run is a claim on nothing, and so is a web
  # fallback; an action that takes no `url` cannot be handed a reference's uri.
  # All three are refused here rather than at acceptance, because all three are
  # facts about the code alone.
  defp check_url_action(%{url_action: nil, web_fallback: true}, _actions),
    do: {:error, {:invalid_declarations, ":web_fallback needs a :url_action to hand a page to"}}

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
