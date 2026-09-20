defmodule YmerNode.Scripts do
  @moduledoc """
  The scripts this node has accepted, and every door they arrive and leave
  through — the context both script tools wrap and the node's own callers use.

  A script is an Elixir module kept as a row and compiled into this VM. What
  makes it *runnable* is not that it is stored: it is that the node has accepted
  the exact code the row holds, and that this boot compiled it.

  ## Acceptance

  `run/3` refuses unless `accepted_hash == code_hash`. That single comparison is
  the whole security claim: code that changed after it was accepted is code
  nobody accepted, so the node stops rather than running it. Today every door
  that writes code also accepts it in the same breath — an authored script, a
  pushed one and the example the build plants are each a deliberate act by
  someone who read the code — and the unaccepted state exists for the door that
  does not exist yet, registry sync, where code arrives from elsewhere and no
  one here has looked at it.

  ```mermaid
  stateDiagram-v2
      [*] --> Runnable : create, push, update, plant

      Runnable --> Unaccepted : sync replaces the code (later)
      Unaccepted --> Runnable : accept
      Runnable --> Broken : a boot this code no longer compiles against
      Runnable --> Broken : a restore whose recompile fails
      Broken --> Runnable : update with code that compiles

      Runnable --> [*] : remove
      Unaccepted --> [*] : remove
      Broken --> [*] : remove

      note right of Runnable
          accepted_hash == code_hash, and
          this boot compiled it. run/3
          refuses in every other state.
      end note
  ```

  `Broken` is never reached by storing: a write compiles first and is refused if
  that fails, so nothing unrunnable is ever stored on purpose. It is reached at
  boot — after a node upgrade moves the contract or a battery underneath it, the
  boot compile fails, the row is **kept** with its diagnostics, and `run/3`
  refuses it with them; dropping the row would destroy the only copy of code the
  operator now has to fix — and by one write-side path that leaves the row
  unchanged: a refused re-accept, or a write whose candidate failed, puts the
  stored code back by compiling it again, and a body that cannot run twice in
  one VM (a named table it creates, a process it registers) fails that compile.
  The row is kept with the diagnostic exactly as at boot, and a restart repairs
  it.

  ## What acceptance refuses

  Five things, and where each is refused:

  | refusal | where |
  | --- | --- |
  | a `url_action` `actions/0` does not declare | `YmerNode.Scripts.Compiler`, at every compile |
  | a `url_action` whose schema has no `url` property | `YmerNode.Scripts.Compiler`, at every compile |
  | a name in `web`, `file` or `other` | here, **before** the compile |
  | a host another accepted script already claims | here, after the compile — inside the loader's message at every write door, in the open at the build's |
  | a throttle another accepted script declares with other parameters | here, beside the host rule and wherever it runs |

  The first two are properties of the code alone, so the compiler settles them
  before a row exists and no write can get past them. The last three depend on
  what *else* is in the database — the references vocabulary and the other
  accepted rows — which the compiler cannot see. All five are checked at every
  acceptance door: `create/1`, `update/2`, `push/1` and `accept/1` — and at
  `check/1`, which promises every refusal `create/1` would give. The build's
  door, `plant_example/0`, checks the host and throttle rules and not the
  name's: its name is derived from a file this repo ships, never from code
  arriving from outside.

  Where each of the last three sits is load-bearing rather than tidy. Compiling
  `Script.X` replaces whatever `Script.X` this VM is running, so a refusal taken
  *after* the compile has already displaced a live script for as long as it
  takes to put it back. Everything readable off the derived name therefore goes
  first — the reserved-name rule, and `create/1`'s own "that name is taken" —
  which is what stops a create from ever reaching the compiler under a name that
  belongs to another script. Only the host and throttle rules need the compiled
  module, and only they are answered afterwards — and they are answered, with
  the row write behind them, **inside the loader's own message**, as the commit
  `YmerNode.Scripts.Loader.load/2` runs between the compile and the recording of
  the facts. That is what makes the far side of the compile gapless: a run
  queued behind the compile is never handed the candidate a refusal is about to
  put back, and the second of two writes claiming one host reads the first's
  row rather than racing it. The row itself is read again inside that message,
  so the name rule and the module rule the door answered from a pre-image are
  answered once more from the row as it stands. `check/1` answers the host and
  throttle rules too, but after the loader has answered and put the stored code
  back — an advisory read, like its `existing` flag: it stores nothing, so a
  stale answer costs nothing but the refused write it failed to predict.

  The host rule exists because `YmerNode.References.Sources` resolves a uri to
  the first claiming script by name. Two scripts claiming one host would still
  give a stable answer, but a silently-losing script is worse than a refused
  one: its author would watch references resolve elsewhere with nothing to read.

  The throttle rule exists because a throttle is one process per name
  (`YmerNode.Scripts.Throttle`), and every request hands it the parameters of
  the script making it: two accepted scripts declaring one name differently would
  have it obey whichever asked last, and a disagreement between two authors about
  one account would be settled by timing. The refusal names the accepted script
  that declared the name first; a script declaring it with the same parameters
  shares the throttle.

  ## Coordination

  ```mermaid
  flowchart TD
      S[YmerNode.Scripts]

      subgraph owned
          Script[Script schema]
          Compiler
          Loader
          Runner
      end

      subgraph external
          Repo[(YmerNode.Repo)]
          Sources[References.Sources]
      end

      S -->|"parse before every write"| Compiler
      S -->|"load with the store as its commit, unload, facts"| Loader
      S -->|"run/3"| Runner
      S --> Script
      S --> Repo
      S -->|"reserved names, claimed hosts"| Sources
  ```

  The store and the VM are two different truths and this module is where they
  are joined. The row says what the node accepted; the loader says what this
  boot managed to compile. `list/0` and `describe/2` answer both, so a script
  that will not compile is visible as such rather than missing.

  ## Design decisions

  - **A write compiles before it lands, always.** `create/1`, `update/2`,
    `push/1` and `plant_example/0` compile the code before touching the
    database, so a row the node holds has compiled at least once on this node
    and the caller's error is a diagnostic rather than a row that never runs.
  - **Exactly one compile per call, through the loader.** The loader compiles and
    records the facts in one message, so the write path never compiles a second
    time to learn what it already knows — script code runs once per write, not
    twice.
  - **The far side of the compile is the loader's message too.** The host and
    throttle rules and the row write are handed to
    `YmerNode.Scripts.Loader.load/2` as its `commit:`, and a remove's row
    delete to `unload/3`'s, so compile, refusal and store — and purge and
    delete — are one queued operation each. Why is § What acceptance refuses
    above.
  - **A compile that is not kept puts the old code back.** Compiling
    `Script.X` unloads whatever `Script.X` this VM had, so a write refused
    *after* its compile would otherwise leave the running script unloaded while
    its row still read accepted. The loader restores the row's code inside the
    same message that compiled the candidate; where there is no row, it forgets
    the name instead. The one refusal that restores nothing is the loader's own
    `run_in_flight`: it compiled nothing, and a restore there would purge the
    live run's tree.
  - **`check/1` restores nothing, because nothing observes its candidate.**
    `YmerNode.Scripts.Loader` compiles the candidate and puts the stored code
    back inside one message, and records no facts for the candidate at all. This
    module hands it the stored code to put back and reads the result; a reader
    arriving mid-check sees the state before it or the state after it, never a
    live script's name answering code nobody accepted.
  - **The name is derived, never given.** `YmerNode.Scripts.Compiler.parse/1`
    reads it from the code's top module, so `update/2` refuses code whose name
    derives to something other than the row being updated — a rename is a remove
    and a create, and doing it silently would leave the old row behind. The
    same rule holds one level down: `Macro.underscore/1` is not injective, so
    `Script.JiraAPI` derives the name `Script.JiraApi` already holds, and a
    replace that landed it would leave two module trees under one row with
    nothing ever purging the first. `update/2` and `push/1` refuse a top module
    that differs from the stored code's; that rename, too, is a remove and a
    create.
  - **`create/1` refuses an existing name** rather than answering the existing
    row the way `YmerNode.References.create_reference/1` does. Two references
    with one uri are the same pointer; two scripts with one name are different
    code, so a silent success would hide a write that did nothing.
  - **Every door that replaces or removes a script's code refuses while a run of
    it is in flight** — `create/1`, `update/2`, `push/1`, `accept/1`, `remove/1`
    and `check/1` alike, because every one of them purges the tree before it
    loads anything. `:code.purge/1` kills a process still executing the old
    code, so landing any of them over a live run would kill a half-finished run
    to make room — the node breaking the read-before-write rule it asks scripts
    to keep. Each door asks `YmerNode.Scripts.Runner.in_flight?/1` first, for an
    early refusal that names the script; the refusal that *holds* is
    `YmerNode.Scripts.Loader`'s, taken in the same message as the purge, because
    a run can start between a door's own look and the purge it leads to. The
    wait is bounded by the timeout cap.
  - **`accept/1` on an already-accepted row changes nothing at all.** No
    recompile, no purge, no fresh acceptance time — it answers the row. Every
    door today accepts in the same breath as it writes, so that is every accept
    this node can currently be asked for, and a re-affirmation an operator makes
    out of caution must not be the thing that kills a run. The compile is kept
    for the stale case registry sync will bring, which is the only case that
    needs one. It follows that a `Broken` row is repaired by `update/2` alone,
    as the diagram above says: accept has nothing to recompile there, because
    the hashes already agree.
  - **No version history.** An `update/2` replaces the code and the previous
    text is gone: a standard script's history is its repository's, an ad-hoc
    script's is the session that wrote it. Revisit if a script is ever lost to a
    bad update.
  - **Declarations are written string-keyed.** The row's `declarations` column
    round-trips through JSON, so what goes in atom-keyed comes back string-keyed;
    writing the string form is what makes a freshly-inserted row and a re-read
    one the same shape, and the references seam reads exactly one of them.
  - **`plant_example/0` compiles outside the loader, and it is the only write
    that does.** It runs inside the migration that plants the example script,
    before `YmerNode.Scripts.Loader` exists; nothing else runs then — no live
    tree to displace, no run to refuse — and the loader compiles the row with
    every other accepted one a moment later at the same boot. What the loader's
    message buys the other doors, it does not need; what acceptance refuses, it
    refuses like them: the host and throttle rules read the accepted rows, and
    the build's example is refused where an operator's own script already
    claims its host.
  """
  import Ecto.Query, warn: false

  alias YmerNode.References.Sources
  alias YmerNode.Repo
  alias YmerNode.Scripts.Compiler
  alias YmerNode.Scripts.Loader
  alias YmerNode.Scripts.Runner
  alias YmerNode.Scripts.Script

  # ─── Runtime configuration ──────────────────────────────────────────

  @doc """
  Whether the migration that plants the example script plants at all
  (`config :ymer_node, YmerNode.Scripts, :plant_example`).

  Defaults to enabled. `config/test.exs` turns it off, so a test database never
  holds a row no case wrote and a listing a case asserts on starts empty;
  `YmerNode.ScriptsTest` calls `plant_example/0` itself.
  """
  def plant_example? do
    :ymer_node
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:plant_example, true)
  end

  # ─── Reading ────────────────────────────────────────────────────────

  @doc """
  Every script, slim: what a worker reads to choose one.

  Each entry carries the row's `name`, `description`, `origin` and `accepted?`,
  the action names, and — from this boot's compile — `loaded?` plus the `error`
  that explains a script that will not run. Ordered by name, so two calls agree.
  """
  def list do
    facts = Loader.all_facts()

    Script
    |> order_by(asc: :name)
    |> Repo.all()
    |> Enum.map(&summarise(&1, Map.get(facts, &1.name)))
  end

  @doc """
  One script in full — everything `list/0` carries plus the contract, the
  acceptance time, the declarations and each action's whole schema.

  Pass `code: true` for the code itself. It is left out by default because a
  worker asking what a script does should not pay for every line of it, and a
  Crosskey-sized script is most of a context window.
  """
  def describe(name, opts \\ []) when is_binary(name) and is_list(opts) do
    with {:ok, script} <- get(name) do
      {:ok, detail(script, Loader.facts(name), Keyword.get(opts, :code, false))}
    end
  end

  @doc "One script's row by name."
  def get(name) when is_binary(name) do
    case Repo.get_by(Script, name: name) do
      nil -> {:error, not_found(name)}
      %Script{} = script -> {:ok, script}
    end
  end

  @doc """
  Compiles code and answers what it would become, writing nothing.

  The door an author knocks on before `create/1`: the derived name, the
  contract, the description, the actions and the declarations, plus any compile
  warnings and `existing` — whether a script of that name is already here. Every
  refusal is the one the write would have given.

  `existing: true` says `create/1` would be refused and `update/2` is the call to
  make. Answering it here is the round trip this door exists to save, and it is
  never left out: a flag that disappears when it is false is a flag a reader
  stops checking.

  The compile itself goes through `YmerNode.Scripts.Loader`, which compiles the
  candidate and puts the stored code back as one operation — reading the row for
  that restore itself. This module reads the row for `existing` and for the
  module rule a replace would apply, and answers the host and throttle rules
  after the loader has restored; all of it is advisory: a check racing a write
  of the same name can answer a flag or a refusal that is already out of date,
  which costs its caller one refused write. The restore is what must not race,
  and that is why it is not this module's.

  Checking compiles, and compiling replaces the tree of that name, so this is
  refused while a run of that name is in flight for the same reason a write is.
  Nothing else about it writes anything.
  """
  def check(code) when is_binary(code) do
    with {:ok, parsed} <- Compiler.parse(code),
         :ok <- check_reserved(parsed.name),
         existing = Repo.get_by(Script, name: parsed.name),
         :ok <- check_same_module(existing, parsed.module),
         :ok <- check_idle(parsed.name),
         {:ok, compiled} <- Loader.check(code),
         :ok <- check_claims(compiled) do
      {:ok, compiled |> Map.drop([:module, :modules]) |> Map.put(:existing, existing != nil)}
    end
  end

  # ─── Writing ────────────────────────────────────────────────────────

  @doc """
  Creates a script from new code, accepted at exactly those bytes — the
  `script_author` door, origin `authored`.

  Refuses a name that already exists, pointing at `update/2`.
  """
  def create(code) when is_binary(code), do: write(code, :create)

  @doc """
  Replaces one script's code — the `script_author` door.

  Refuses code whose derived name is not `name`, and refuses while a run of that
  script is in flight.
  """
  def update(name, code) when is_binary(name) and is_binary(code) do
    with {:ok, _script} <- get(name),
         {:ok, parsed} <- Compiler.parse(code),
         :ok <- check_same_name(name, parsed.name) do
      write(code, :update)
    end
  end

  @doc """
  Lands a file as a script, creating or replacing by its derived name — the CLI
  door, origin `pushed`.

  Create-or-update rather than one or the other: a human pointing at a file has
  said what they want, and making them know first whether the node already has
  it would be a question with no purpose.
  """
  def push(code) when is_binary(code), do: write(code, :push)

  @doc """
  Plants the example script the image ships as an accepted row — the build's
  door, origin `shipped` — unless a row of its name is already here, which is
  then answered untouched: an operator's own copy is never overwritten.

  The one write that compiles outside `YmerNode.Scripts.Loader`. It runs inside
  the migration that calls it, before the loader exists, and nothing else runs
  then: no live tree to displace, no run to refuse, no facts to record, since
  the loader compiles every accepted row a moment later at the same boot. The
  tree is purged as soon as the metadata is read, so the loader meets the VM as
  it would have without this. What acceptance refuses, this door refuses too:
  the host and throttle rules read the accepted rows, not the loader, and run
  here in the open between the compile and the row.

  `{:error, {:host_claimed, detail}}` is the refusal every write door gives when
  an accepted script already claims a host the example declares — here, an
  operator's own script, written before this build arrived, which is a choice
  this build has no business overriding: the migration plants nothing, says so,
  and records itself all the same, so that install never gets the example from
  a boot. Any other `{:error, {reason, detail}}` is a shipped file that does not
  compile as a script — a build's defect, which the suite compiling those bytes
  exists to catch before any image carries them. An `{:error, changeset}` from
  the row write is this codebase's own bug — the compiler produced every value
  the changeset checks — and the migration lets it crash the boot loudly rather
  than naming a next step nobody has.
  """
  def plant_example do
    code = File.read!(example_path())

    with {:ok, parsed} <- Compiler.parse(code) do
      case Repo.get_by(Script, name: parsed.name) do
        %Script{} = existing -> {:ok, existing}
        nil -> plant(code, parsed.module)
      end
    end
  end

  @doc "Where the example script sits in this build."
  def example_path, do: Application.app_dir(:ymer_node, "priv/scripts/hex.exs")

  # The purge is unconditional because the compile loads the tree before it can
  # still refuse: `Compiler.compile/1` checks the contract, the callbacks and
  # the metadata with the modules already loaded, so its refusals arrive with a
  # tree behind them. Purging only the success path would leave one resident on
  # exactly the paths this door's docs promise it does not.
  defp plant(code, module) do
    compiled = Compiler.compile(code)
    Compiler.purge(module)

    with {:ok, compiled} <- compiled do
      accept_planted(compiled, code)
    end
  end

  # The far side of the compile for the build's door — the host and throttle
  # rules, then the row — run in the open rather than inside the loader's message
  # (`accept_and_store/3`), because nothing runs beside a migration. The purge
  # above has already run: this door's refusals leave no tree behind either.
  defp accept_planted(compiled, code) do
    with :ok <- check_claims(compiled) do
      land(nil, attrs(compiled, code, :plant))
    end
  end

  @doc """
  Marks the stored code accepted, as of now.

  A row already accepted at its current code is answered unchanged — nothing is
  compiled, nothing is purged, and the acceptance time stays where it was. That
  is every accept this node can be asked for today, because every door accepts
  in the same breath as it writes.

  The rest is the verb registry sync will need: stored code nobody here has
  looked at is compiled, and the acceptance refusals run as they do at any other
  door.
  """
  def accept(name) when is_binary(name) do
    with {:ok, script} <- get(name) do
      if Script.accepted?(script), do: {:ok, script}, else: reaccept(script)
    end
  end

  defp reaccept(%Script{} = script) do
    with :ok <- check_reserved(script.name),
         :ok <- check_idle(script.name) do
      Loader.load(script.code, idle_guard: true, commit: &accept_stored(&1, script))
    end
  end

  # The write's far side (`accept_and_store/4`) for the code a row already
  # holds: the host and throttle rules, then the acceptance itself.
  defp accept_stored(compiled, %Script{} = script) do
    with :ok <- check_claims(compiled) do
      script
      |> Script.changeset(%{accepted_hash: script.code_hash, accepted_at: now()})
      |> Repo.update()
    end
  end

  @doc """
  Deletes a script and unloads its module tree.

  Refuses while a run of that script is in flight, for the same reason
  `update/2` does.
  """
  def remove(name) when is_binary(name) do
    with {:ok, script} <- get(name),
         :ok <- check_idle(name),
         {:ok, _deleted} <- unload(script, fn -> delete_row(script) end) do
      {:ok, script}
    end
  end

  # Inside the loader's message, after the purge — it is `unload/3`'s commit —
  # so no write lands a fresh tree between the tree going and the row going. A
  # remove racing another remove finds the row already gone: that is
  # `not_found`, rendered like every other refusal, not a match failing at a
  # door where every other answer is a message.
  defp delete_row(%Script{id: id, name: name}) do
    case Repo.delete_all(from s in Script, where: s.id == ^id) do
      {1, _rows} -> {:ok, :deleted}
      {0, _rows} -> {:error, not_found(name)}
    end
  end

  # ─── Running ────────────────────────────────────────────────────────

  @doc """
  Runs one action of one script.

  The node's own callers reach a script through here and not through
  `YmerNode.Scripts.Runner` directly, so a scheduled run inside the node gets the
  same acceptance check, the same batteries, the same deadline and the same
  isolation an MCP call gets.
  """
  def run(name, action, args) when is_binary(name) and is_binary(action) and is_map(args) do
    with {:ok, script} <- get(name) do
      Runner.run(script, action, args)
    end
  end

  # ─── The write path ─────────────────────────────────────────────────

  # Parse first, because parsing touches nothing: every refusal that can be read
  # off the derived name is answered here, before the compile unloads anything.
  # What is left needs the compiled module, and it goes to the loader as the
  # commit its message runs on the far side of the compile.
  defp write(code, door) do
    with {:ok, parsed} <- Compiler.parse(code),
         :ok <- check_reserved(parsed.name),
         existing = Repo.get_by(Script, name: parsed.name),
         :ok <- check_free(existing, door),
         :ok <- check_same_module(existing, parsed.module),
         :ok <- check_idle(parsed.name) do
      Loader.load(code, idle_guard: true, commit: &accept_and_store(&1, code, door))
    end
  end

  # The far side of the compile, run inside the loader's message: the host and
  # throttle rules need the compiled declarations, and the row write has to land
  # before the loader answers anyone else — a second write reading the accepted
  # rows, or a run asking for this name's module. A refusal here leaves a
  # compiled candidate the loader puts back in the same message, so no reader
  # ever holds it. Compiling `Script.X` had unloaded whatever `Script.X` this VM
  # already had — `YmerNode.Scripts.Compiler.compile/1` must, or the two trees
  # would collide — which is why that restore exists at all.
  defp accept_and_store(compiled, code, door) do
    with :ok <- check_claims(compiled) do
      store(compiled, code, door)
    end
  end

  # The row is read again here, inside the loader's message, where no other
  # write can land between this read and the write: the door's own look was a
  # fast path over a row that may have changed while this write queued. A
  # create meets the name another create just took; an update finds its row
  # removed; a replace meets a row whose module a concurrent create spelled
  # differently — each answered as the door would have answered it.
  defp store(compiled, code, door) do
    with {:ok, existing} <- row_for(compiled.name, door),
         :ok <- check_same_module(existing, compiled.module) do
      land(existing, attrs(compiled, code, door))
    end
  end

  defp row_for(name, door) do
    case {Repo.get_by(Script, name: name), door} do
      {nil, :update} -> {:error, not_found(name)}
      {%Script{} = existing, :create} -> {:error, exists(existing)}
      {existing, _door} -> {:ok, existing}
    end
  end

  defp land(nil, attrs), do: %Script{} |> Script.changeset(attrs) |> Repo.insert()
  defp land(%Script{} = existing, attrs), do: existing |> Script.changeset(attrs) |> Repo.update()

  defp attrs(compiled, code, door) do
    hash = Script.hash(code)

    %{
      name: compiled.name,
      code: code,
      code_hash: hash,
      accepted_hash: hash,
      accepted_at: now(),
      origin: origin(door),
      contract: compiled.contract,
      description: compiled.description,
      declarations: row_declarations(compiled.declarations)
    }
  end

  # Atom keys in, string keys out: the column round-trips through JSON, so this
  # is the shape a re-read row has and the shape the references seam expects — a
  # throttle's parameters included, which is the shape the other accepted rows'
  # throttles are compared in.
  defp row_declarations(declarations) do
    %{
      "hosts" => declarations.hosts,
      "url_action" => declarations.url_action && Atom.to_string(declarations.url_action),
      "secrets" => declarations.secrets,
      "throttles" => row_throttles(declarations.throttles)
    }
  end

  defp row_throttles(throttles) do
    Map.new(throttles, fn {name, parameters} -> {name, string_keys(parameters)} end)
  end

  defp string_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {Atom.to_string(key), string_keys(value)} end)

  defp string_keys(value), do: value

  # The door says who is writing: a human's file arrives pushed, the build's
  # example arrives shipped, and everything else is authored over MCP.
  defp origin(:push), do: "pushed"
  defp origin(:plant), do: "shipped"
  defp origin(_authored), do: "authored"

  defp exists(%Script{name: name}) do
    {:name_taken, "a script named #{name} already exists — update it instead of creating it"}
  end

  defp not_found(name), do: {:not_found, "no script named #{name}"}

  # ─── Acceptance ─────────────────────────────────────────────────────

  # `create` alone refuses a name that is taken, and it refuses it before the
  # compile: a candidate reaching the compiler under another script's name would
  # replace that script's module for as long as the refusal took. `row_for/2`
  # keeps the same refusal for two concurrent creates, which both pass this look
  # and then queue on the loader — the second meets it there, deterministically,
  # and the loader puts the first's freshly stored code back.
  defp check_free(%Script{} = existing, :create), do: {:error, exists(existing)}
  defp check_free(_existing, _door), do: :ok

  # `Macro.underscore/1` is not injective — `Script.JiraApi` and `Script.JiraAPI`
  # both derive `jira_api` — so a replace whose top module is a different atom
  # from the stored code's would land a second tree under one name and orphan
  # the first: nothing would ever purge it, because every later purge parses
  # the STORED code. Refused before the compile, the way a rename is — and once
  # more inside the loader's message (`store/3`), against the row as it stands
  # then, for the create that landed while this replace queued.
  defp check_same_module(nil, _module), do: :ok

  defp check_same_module(%Script{name: name, code: stored}, module) do
    case Compiler.parse(stored) do
      {:ok, %{module: ^module}} ->
        :ok

      {:ok, %{module: other}} ->
        {:error,
         {:module_mismatch,
          "#{name} is #{inspect(other)} and this code is #{inspect(module)} — two " <>
            "modules spelling one name; remove #{name} and create it again to change " <>
            "its module"}}

      {:error, _unparseable} ->
        :ok
    end
  end

  defp check_reserved(name) do
    if name in Sources.builtin_sources() do
      {:error,
       {:reserved_name,
        "#{name} is a built-in reference source; a script of that name would shadow it"}}
    else
      :ok
    end
  end

  defp check_hosts(_name, []), do: :ok

  defp check_hosts(name, hosts) do
    case Enum.find(claimed_hosts(name), fn {host, _by} -> host in hosts end) do
      nil ->
        :ok

      {host, by} ->
        {:error, {:host_claimed, "#{host} is already claimed by the accepted script #{by}"}}
    end
  end

  # The seam's own read, less this script's row. `YmerNode.References.Sources`
  # already reads the accepted rows' declarations — and only the accepted ones,
  # so an unaccepted row cannot hold a host hostage — and a second spelling of
  # that query here would be one that drifts from it.
  defp claimed_hosts(name) do
    for %{name: other, hosts: hosts} <- Sources.declarations(),
        other != name,
        host <- hosts,
        do: {host, other}
  end

  # Both rules that read the other accepted rows, in the order a refusal names
  # them: a claimed host first, then a throttle declared with other parameters.
  defp check_claims(compiled) do
    with :ok <- check_hosts(compiled.name, compiled.declarations.hosts) do
      check_throttles(compiled.name, compiled.declarations.throttles)
    end
  end

  defp check_throttles(_name, throttles) when map_size(throttles) == 0, do: :ok

  defp check_throttles(name, throttles) do
    declared = row_throttles(throttles)

    case Enum.find(declared_throttles(name), &differs?(&1, declared)) do
      nil ->
        :ok

      {throttle, _parameters, by} ->
        {:error,
         {:throttle_conflict,
          "#{throttle} is declared by the accepted script #{by} with other parameters"}}
    end
  end

  defp differs?({throttle, parameters, _by}, declared) do
    case Map.fetch(declared, throttle) do
      {:ok, ours} -> ours != parameters
      :error -> false
    end
  end

  # The accepted rows' throttles, less this script's own, oldest row first, so a
  # conflict names the script that declared the name before this one. Read off
  # the rows in their string-keyed shape, like the host rule's read; a row
  # written before throttles existed declares none.
  defp declared_throttles(name) do
    query =
      from script in Script.accepted(),
        where: script.name != ^name,
        order_by: [asc: script.inserted_at, asc: script.name],
        select: {script.name, script.declarations}

    for {other, declarations} <- Repo.all(query),
        {throttle, parameters} <- Map.get(declarations, "throttles", %{}),
        do: {throttle, parameters, other}
  end

  # ─── Guards on a write ──────────────────────────────────────────────

  defp check_same_name(name, name), do: :ok

  defp check_same_name(name, derived) do
    {:error,
     {:name_mismatch,
      "this code is #{derived}, not #{name} — remove #{name} and create #{derived} to rename it"}}
  end

  defp check_idle(name) do
    if Runner.in_flight?(name) do
      {:error, {:run_in_flight, "#{name} has a run in flight; retry when it ends"}}
    else
      :ok
    end
  end

  # The purge is the step that can still be refused — a run may have started
  # since `check_idle/1` looked — so the row delete rides the same message as
  # its commit, after it: a row deleted ahead of a refused unload would leave
  # code running with nothing left to describe it, and a row deleted beside the
  # message would let a queued write land a fresh tree in between. A row whose
  # code no longer parses has no tree this boot could have compiled: nothing to
  # purge, and the delete still lands inside the message.
  defp unload(%Script{name: name, code: code}, commit) do
    module =
      case Compiler.parse(code) do
        {:ok, %{module: module}} -> module
        {:error, _unparseable} -> nil
      end

    Loader.unload(name, module, idle_guard: true, commit: commit)
  end

  # ─── Shaping a read ─────────────────────────────────────────────────

  defp summarise(%Script{} = script, facts) do
    facts = facts || absent_facts()

    %{
      name: script.name,
      description: script.description,
      origin: script.origin,
      accepted?: Script.accepted?(script),
      actions: facts.actions |> Map.keys() |> Enum.sort(),
      loaded?: facts.loaded?,
      error: facts.error
    }
  end

  defp detail(%Script{} = script, facts, code?) do
    facts = facts || absent_facts()

    script
    |> summarise(facts)
    |> Map.merge(%{
      contract: script.contract,
      accepted_at: script.accepted_at,
      declarations: script.declarations,
      actions: facts.actions,
      warnings: facts.warnings,
      code: if(code?, do: script.code)
    })
  end

  # A row nothing in this boot has compiled — no failure recorded either, because
  # nothing tried. `describe` still answers, and says so.
  defp absent_facts do
    %{
      loaded?: false,
      actions: %{},
      warnings: [],
      error: {:not_compiled, "not compiled this boot"}
    }
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
