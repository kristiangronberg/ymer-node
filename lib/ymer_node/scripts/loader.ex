defmodule YmerNode.Scripts.Loader do
  @moduledoc """
  Owns the VM's script module trees: every compile and every purge goes through
  this process, and it remembers what each one produced.

  ## Why a process at all

  Compiling is a mutation of a global table. Two concurrent writes of one script
  would race on `:code.purge/1` and could leave the tree half-unloaded; two
  writes of different scripts would interleave diagnostics. A single GenServer
  makes every compile a queued, whole operation.

  Compiles happen at boot, at a write, and at a `check`. The last of those is an
  interactive call, so the queue sits on a caller's path: a candidate that takes
  the compiler's whole bound holds every other reader behind it for that long.
  That is the price of the guarantee below, and it is bounded — the compile and
  the metadata read each carry their own deadline, so a looping candidate costs
  a wait and never the node.

  It is also where the **per-boot facts** live: the modules a script's last
  compile defined, the warnings it carried, and the error it failed with. Those
  are facts about this VM and not about the row, so they belong in memory and
  die with the node; a column would claim they survive a restart, and they do
  not.

  ## No purge lands over a live run

  A write and a `check` both purge the tree they are about to replace, and
  `:code.purge/1` kills a process still executing the old code. A caller cannot
  take that refusal for itself: between its own look at the registry and the
  purge, a run can start. So the look is taken **here**, in the same message as
  the purge — `idle_guard: true` on `load/2` and `unload/3`, and always on
  `check/1`.

  It holds because of the order the two sides work in. A run registers itself
  before it asks for a module, and the only place a module comes from is this
  process. A run that registered before this message is seen, and the purge is
  refused; a run that registers after it is queued behind this message and is
  handed the tree this message leaves. There is no third case.

  ## A write lands whole

  The tree a message leaves has to be one a row vouches for. A write's compile
  displaces the stored script's tree with the candidate's, and the rules that
  can still refuse the candidate — the host and throttle rules read the
  accepted rows, and the row write itself can meet a name another write just
  took — need the
  compiled module, so they cannot run ahead of the compile. Run in the caller
  after it, they leave two gaps: a run queued behind the compile is handed the
  candidate before the refusal lands, and executes code the node is in the act
  of refusing; and two writes claiming one host each read the rows before the
  other has stored its own, and both land. `load/2`'s `commit:` closes both by
  running those rules and the row write **inside the message**, between the
  compile and the recording of the facts: what a queued reader sees is the
  stored candidate or the restored old code, never the in-between, and the
  second of two writes reads the first's row.

  A candidate that is not kept — its compile failed, or its commit refused it —
  is put back inside the same message: the stored row's code compiled again and
  recorded, or the name forgotten where there is no row. The facts always say
  what this VM holds when the call answers. A refused write therefore costs its
  message two compiles, the candidate's and the restore's — the shape `check/1`
  has always had.

  A remove is the same operation from the other side: `unload/3` takes the row
  delete as its `commit:`, so the tree and the row go inside one message and no
  write can land a fresh tree between the two.

  ## Compile at boot, and at every write

  `init/1` compiles every accepted row before the supervisor moves on, which is
  why this child sits after the migrator and before the HTTP listener: the node
  never accepts a call it cannot serve. A row that fails to compile is **kept**,
  its diagnostics recorded, its failure logged — and the boot continues. A node
  that refused to start because one script stopped compiling would take the
  notebook and the registry down with it, and the operator would have no way in
  to fix the script. A row that *hangs* rather than fails is the same problem
  wearing a worse face — the supervisor waits on `init/1` with no bound of its
  own — so the deadline that answers it belongs to the compile itself and lives
  in `YmerNode.Scripts.Compiler`; a hung row arrives here as an ordinary
  refusal and is kept and logged like any other.

  First-use compilation is deliberately not an option: the first caller would
  pay for it, and a failure would surface in a tool result rather than in the
  log an operator reads after a restart.

  ## What it reads for itself

  Two reads are this module's own, spelled with Ecto rather than through
  `YmerNode.Scripts` — which calls *this* module on every write, so routing
  them through the context would make the pair mutually recursive at compile
  time for a query that is the same query either way: the accepted rows' name
  and code at boot, and one row's code for a restore. Everything else this
  process touches in the database arrives as a write's `commit:` — the
  context's own functions, handed over as a value rather than called by name.
  """
  use GenServer

  import Ecto.Query, only: [from: 2]

  alias YmerNode.Repo
  alias YmerNode.Scripts.Compiler
  alias YmerNode.Scripts.Script

  require Logger

  @call_timeout 60_000

  # The registry a run registers itself in, read here rather than through
  # `YmerNode.Scripts.Runner`: a run asks *this* process for its module, so a
  # call the other way would make the pair mutually recursive at compile time
  # for one lookup. Only a guarded message reads it, and a guarded message
  # arrives only from a door the boot wiring has already started it for.
  @registry YmerNode.Scripts.Runs

  # ─── Runtime configuration ──────────────────────────────────────────

  @doc """
  Whether `init/1` compiles the accepted rows at boot
  (`config :ymer_node, YmerNode.Scripts.Loader, :boot_compile`).

  Defaults to enabled, and `start_link/1`'s own `:boot_compile` option wins over
  it, so a test that starts this process itself can turn the boot read off
  without touching VM-global config.

  `config/test.exs` disables it for the same reason
  `YmerNode.Notebook.VecLoadCheck` is disabled there: the sandbox holds no
  checked-out connection at application start, so the boot read would fail
  against a perfectly healthy build. A test that wants the boot behaviour calls
  `boot_compile/0` itself.
  """
  def boot_compile? do
    :ymer_node
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:boot_compile, true)
  end

  # ─── Public API ─────────────────────────────────────────────────────

  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Compiles one script's code into the VM, replacing whatever tree it had.

  Answers `YmerNode.Scripts.Compiler.compile/1`'s own result — with `commit:`,
  the commit's — and records the script's facts on success. A candidate that is
  not kept is put back before this call answers: the stored row's code is
  compiled again and recorded, success or failure, because the candidate's
  compile had already purged it; where there is no row, the name is forgotten.
  Nothing is ever recorded for a candidate that was not kept, and the facts say
  what the VM holds when the call answers.

  `commit: fun` runs **inside this process**, between the candidate's compile
  and the recording of its facts: `fun.(compiled)` answers `{:ok, value}` to
  keep the candidate — `value` is then this call's answer — or
  `{:error, reason}` to refuse it, which restores the stored code exactly as a
  failed compile does. It is how a write puts the host and throttle rules and
  the row write on the far side of the compile with no gap (§ A write lands
  whole): every
  other compile, every restore and every `facts/1` read queues behind the
  whole message. A commit that raises or exits is refused as
  `{:error, {:commit_failed, detail}}` rather than taking this process, and
  with it every script's facts, down for one write.

  `idle_guard: true` refuses with `{:error, {:run_in_flight, detail}}` while a
  run of the script this code derives to is in flight — before anything is
  purged, so that refusal alone restores nothing. Every production caller
  passes it: `YmerNode.Scripts`' write and accept doors. The unguarded form is
  the test suite's, for a fixture compiled with no row and no run behind it.
  Boot never comes through here — `init/1` compiles the accepted rows through
  `YmerNode.Scripts.Compiler` directly, before any run exists.
  """
  def load(code, opts \\ []) when is_binary(code) and is_list(opts) do
    commit = Keyword.get(opts, :commit, &{:ok, &1})
    GenServer.call(__MODULE__, {:load, code, guarded?(opts), commit}, @call_timeout)
  end

  @doc """
  Unloads one script's module tree and forgets its facts.

  Takes `idle_guard: true` for the reason `load/2` does: a remove purges the
  tree a run may be executing inside. Takes `commit:` for the reason `load/2`
  does too: a remove's row delete runs inside this message, after the purge,
  so no write can land a fresh tree between the tree going and the row going —
  `fun.()` answers `{:ok, value}` or `{:error, reason}`, and that is this
  call's answer once the tree is gone and the name forgotten, whichever it
  is. Without a commit the call answers `:ok`. `top_module` may be `nil` for a
  row whose code this boot could not parse: there is no tree to purge, and the
  commit still runs inside the message.
  """
  def unload(name, top_module, opts \\ [])
      when is_binary(name) and is_atom(top_module) and is_list(opts) do
    commit = Keyword.get(opts, :commit, fn -> :ok end)

    GenServer.call(
      __MODULE__,
      {:unload, name, top_module, guarded?(opts), commit},
      @call_timeout
    )
  end

  @doc """
  Compiles a candidate and puts the stored code back, as one operation.

  What `check` needs. Compiling `Script.X` unloads whatever `Script.X` this VM
  had, so the row of that name is read **here** and compiled again before this
  call answers, and the candidate's own facts are never recorded. Every step is
  inside this one message, which is what makes the pair indivisible: no other
  caller is handed the candidate's module or its metadata, and no write can land
  between the read and the restore. A caller that read the row for itself and
  passed the code in would restore whatever the row held when *it* looked — and
  a write that landed meanwhile would leave the VM running code the row no
  longer holds, which is the acceptance invariant broken from the inside.

  Always guarded: the candidate's compile purges the running tree exactly as a
  write does.
  """
  def check(code) when is_binary(code) do
    GenServer.call(__MODULE__, {:check, code}, @call_timeout)
  end

  @doc """
  What this VM knows about one script right now — `nil` for a script this boot
  has never compiled.

  `%{loaded?: boolean, module: module | nil, modules: [module], contract: integer | nil,
  description: String.t() | nil, actions: map, declarations: map | nil,
  warnings: [String.t()], error: nil | {atom, String.t()}}`.

  Every key is present either way: a script that would not compile answers the
  same shape with `loaded?: false`, no module, no metadata and its `error` set,
  so a caller rendering a listing never has to ask which shape it got.
  """
  def facts(name) when is_binary(name),
    do: GenServer.call(__MODULE__, {:facts, name}, @call_timeout)

  @doc "Every script's facts, keyed by name."
  def all_facts, do: GenServer.call(__MODULE__, :all_facts, @call_timeout)

  @doc """
  Compiles every accepted row, recording each outcome. Answers the number
  loaded and the number refused.

  Public so a test can exercise the boot path without booting; `init/1` is its
  only other caller.
  """
  def boot_compile do
    GenServer.call(__MODULE__, :boot_compile, @call_timeout)
  end

  # ─── GenServer ──────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    state = %{scripts: %{}}

    if Keyword.get(opts, :boot_compile, boot_compile?()) do
      {:ok, state |> compile_accepted() |> elem(1)}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_call({:load, code, guard?, commit}, _from, state) do
    case Compiler.parse(code) do
      {:ok, parsed} -> load_reply(state, code, parsed, guard?, commit)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # The purge and the forget stand whatever the commit answers: a row the
  # commit finds already gone has no tree to keep either.
  def handle_call({:unload, name, top_module, guard?, commit}, _from, state) do
    case idle_name(name, guard?) do
      :ok ->
        if top_module, do: Compiler.purge(top_module)
        {:reply, committed(commit), %{state | scripts: Map.delete(state.scripts, name)}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:check, code}, _from, state) do
    case Compiler.parse(code) do
      {:ok, parsed} -> check_reply(state, code, parsed)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:facts, name}, _from, state), do: {:reply, Map.get(state.scripts, name), state}

  def handle_call(:all_facts, _from, state), do: {:reply, state.scripts, state}

  def handle_call(:boot_compile, _from, state) do
    {counts, state} = compile_accepted(state)
    {:reply, counts, state}
  end

  # ─── Private ────────────────────────────────────────────────────────

  defp guarded?(opts), do: Keyword.get(opts, :idle_guard, false)

  # The guard's refusal compiles nothing, so it restores nothing. Past it the
  # candidate's compile has purged the stored tree, and every outcome but a
  # kept candidate — a compile that fails, a commit that refuses — ends in the
  # restore, inside this same message.
  defp load_reply(state, code, %{name: name, module: module}, guard?, commit) do
    case idle_name(name, guard?) do
      :ok ->
        case compile_and_commit(code, commit) do
          {:ok, compiled, value} -> {:reply, {:ok, value}, record_success(state, compiled)}
          {:error, reason} -> {:reply, {:error, reason}, restore(state, name, module)}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # `compiled` is what the facts record; `value` is what the caller is told.
  defp compile_and_commit(code, commit) do
    with {:ok, compiled} <- Compiler.compile(code),
         {:ok, value} <- committed(fn -> commit.(compiled) end) do
      {:ok, compiled, value}
    end
  end

  # A commit runs the context's code in this process. One that raises must be
  # a refusal like any other — the stored code goes back — and never the end
  # of this process and of every script's facts with it.
  defp committed(commit) do
    commit.()
  rescue
    exception -> {:error, {:commit_failed, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:commit_failed, Exception.format_banner(kind, reason)}}
  end

  # The candidate's result is taken first and the restore runs after it, in this
  # order and named so, rather than left to the order a tuple's elements happen
  # to be evaluated in.
  defp check_reply(state, code, %{name: name, module: module}) do
    case idle_name(name, true) do
      :ok ->
        result = Compiler.compile(code)
        {:reply, result, restore(state, name, module)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # The candidate's tree goes, and the row's own code goes back — read here, in
  # the message that compiled the candidate, so nothing else observes either
  # step. The read belongs here and not to the caller: a row read before the
  # compile can have been replaced by a write in between, and restoring what it
  # said then would leave the VM running code the row no longer holds. A stored
  # script that no longer compiles records the failure it now has, which is the
  # truth about this boot and what `describe` should show. Where there is no
  # row the name is forgotten: the facts must not say `loaded?` about a tree
  # this purge has just removed.
  defp restore(state, name, module) do
    Compiler.purge(module)

    case stored_code(name) do
      {:ok, nil} -> %{state | scripts: Map.delete(state.scripts, name)}
      {:ok, code} -> reload(state, name, code)
      {:error, detail} -> record_failure(state, name, {:restore_failed, detail})
    end
  end

  defp reload(state, name, code) do
    case Compiler.compile(code) do
      {:ok, compiled} -> record_success(state, compiled)
      {:error, reason} -> record_failure(state, name, reason)
    end
  end

  # A read that fails is not "no row": that answer would forget a script whose
  # row may well exist. The purge has already run, so the truthful facts are a
  # tree that is gone and the reason it was not put back — logged, as the boot
  # read's failure is, because an operator is who can act on it — and never a
  # raise inside this process, which would take every script's facts with it.
  defp stored_code(name) do
    case Repo.get_by(Script, name: name) do
      nil -> {:ok, nil}
      %Script{code: code} -> {:ok, code}
    end
  rescue
    exception ->
      detail = Exception.message(exception)
      Logger.error("scripts: could not read #{name} to put it back: #{detail}")
      {:error, detail}
  end

  # The name a guard needs comes from a parse, which runs none of the script's
  # own code and is the same walk the compile does first.
  defp idle_name(_name, false), do: :ok

  defp idle_name(name, true) do
    if Registry.lookup(@registry, name) == [] do
      :ok
    else
      {:error, {:run_in_flight, "#{name} has a run in flight; retry when it ends"}}
    end
  end

  defp compile_accepted(state) do
    Enum.reduce(accepted_rows(), {%{loaded: 0, refused: 0}, state}, &compile_row/2)
  end

  defp accepted_rows do
    Repo.all(
      from script in Script.accepted(),
        select: {script.name, script.code},
        order_by: script.name
    )
  rescue
    exception ->
      Logger.error("scripts: could not read the accepted rows: #{Exception.message(exception)}")
      []
  end

  # A row that will not compile is KEPT, and the boot goes on. Refusing to boot
  # would take the notebook and the registry down over one script, and leave the
  # operator no way in to fix it.
  defp compile_row({name, code}, {counts, state}) do
    case Compiler.compile(code) do
      {:ok, compiled} ->
        {Map.update!(counts, :loaded, &(&1 + 1)), record_success(state, compiled)}

      {:error, {reason, detail}} ->
        Logger.error("scripts: #{name} did not compile at boot (#{reason}): #{detail}")
        {Map.update!(counts, :refused, &(&1 + 1)), record_failure(state, name, {reason, detail})}
    end
  end

  # The contract, description, actions and declarations the compiler already read
  # are kept here rather than re-read later. `YmerNode.Scripts.list/0` and
  # `describe` need every action's schema, and asking each loaded module for it
  # would mean running script code — unbounded, in the caller's process — once
  # per row, for what is a listing.
  defp record_success(state, compiled) do
    facts = %{
      loaded?: true,
      module: compiled.module,
      modules: compiled.modules,
      contract: compiled.contract,
      description: compiled.description,
      actions: compiled.actions,
      declarations: compiled.declarations,
      warnings: compiled.warnings,
      error: nil
    }

    put_in(state.scripts[compiled.name], facts)
  end

  defp record_failure(state, name, error) do
    facts = %{
      loaded?: false,
      module: nil,
      modules: [],
      contract: nil,
      description: nil,
      actions: %{},
      declarations: nil,
      warnings: [],
      error: error
    }

    put_in(state.scripts[name], facts)
  end
end
