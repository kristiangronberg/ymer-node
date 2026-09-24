defmodule YmerNode.ScriptsTest do
  @moduledoc """
  Every case here writes rows, so `YmerNode.DataCase`'s sandbox owns it and the
  module is not async. Two pieces of state are **not** sandboxed and are managed
  by hand: the VM's module table and the loader's per-boot facts. `create!/2`
  registers a purge for each script it compiles, and every fixture segment
  carries `System.unique_integer/1`, so no case can see another's module or
  another's facts.

  A third piece is VM-global and belongs to one case: the secrets path, which
  the missing-secret case points at its own `tmp_dir` and restores on exit. It
  can do that safely because this module is not async — ExUnit runs every async
  module before any sync one, so nothing else is in flight to see the change.

  The stale-hash case in "run/3" is the acceptance invariant's proof and not a
  routine refusal test: it plants a hash no code hashes to and shows the run
  refused. Deleting it would leave the node's one security claim ungated.

  The two in-flight cases are its pair on the write side: they start a run that
  sleeps and then make a write, which is the only way to reach the refusal at
  all. Both wait for the run to register rather than sleeping a fixed time, so a
  slow machine makes them slower and never flaky.
  """
  use YmerNode.DataCase

  alias YmerNode.Scripts
  alias YmerNode.Scripts.Compiler
  alias YmerNode.Scripts.Loader
  alias YmerNode.Scripts.Runner
  alias YmerNode.Scripts.Script
  alias YmerNode.Secrets

  describe "check/1" do
    test "answers what the code would become and writes nothing" do
      segment = segment()

      assert {:ok, checked} = Scripts.check(code(segment))
      assert checked.name == Macro.underscore(segment)
      assert checked.contract == 1
      assert checked.description == "the #{segment} script"
      assert Map.keys(checked.actions) |> Enum.sort() == [:fetch, :ping]
      assert checked.declarations == %{hosts: [], url_action: nil, secrets: [], throttles: %{}}

      # The negative half of the flag `create` is about to be judged by.
      assert checked.existing == false

      assert Repo.aggregate(Script, :count) == 0
    end

    test "refuses code that will not compile" do
      assert {:error, {:missing_contract, _detail}} =
               Scripts.check("defmodule Script.Bare do\nend\n")

      assert Repo.aggregate(Script, :count) == 0
    end

    test "refuses a reserved name, as create would" do
      purge_on_exit("Web")

      assert {:error, {:reserved_name, _detail}} = Scripts.check(code("Web"))
      assert Repo.aggregate(Script, :count) == 0
    end

    test "refuses a host another accepted script claims, as create would" do
      claimed = ~s|%{hosts: ["hex.pm"], url_action: :fetch, secrets: []}|
      first = create!(segment(), claimed)

      other = segment()
      purge_on_exit(other)

      assert {:error, {:host_claimed, message}} = Scripts.check(code(other, claimed))
      assert message =~ "hex.pm is already claimed"
      assert %{loaded?: true} = Loader.facts(first.name)
      refute Code.ensure_loaded?(Module.concat(["Script", other]))
      assert Repo.aggregate(Script, :count) == 1
    end

    test "refuses a throttle another accepted script declares otherwise, as create would" do
      create!(segment(), throttled("acct", "rate: 60, burst: 2"))

      other = segment()
      purge_on_exit(other)

      assert {:error, {:throttle_conflict, _message}} =
               Scripts.check(code(other, throttled("acct", "rate: 30, burst: 2")))

      assert Repo.aggregate(Script, :count) == 1
    end

    test "refuses code whose top module differs from the stored one, as update would" do
      base = "Case#{System.unique_integer([:positive])}"
      stored = create!(base <> "Api")
      upper = base <> "API"
      purge_on_exit(upper)

      assert {:error, {:module_mismatch, _message}} = Scripts.check(code(upper))
      assert Code.ensure_loaded?(Module.concat(["Script", base <> "Api"]))
      refute Code.ensure_loaded?(Module.concat(["Script", upper]))
      assert Repo.get_by!(Script, name: stored.name).code == stored.code
    end

    @tag doc: """
         The answer an author needs before `create`, and the state of the node
         afterwards. `existing` is what saves the round trip: without it the
         only way to learn that `create` will be refused is to call it. And the
         candidate's compile displaced the running script to make room — it is
         back, it is the STORED code that is back, and the loader's facts never
         showed the candidate at all, because both halves happened inside one
         message.
         """
    test "reports the name is taken and leaves the stored script loaded" do
      segment = segment()
      script = create!(segment)
      candidate = String.replace(code(segment), "the #{segment} script", "a candidate")

      assert {:ok, checked} = Scripts.check(candidate)
      assert checked.description == "a candidate"
      assert checked.existing == true

      assert %{loaded?: true, description: description} = Loader.facts(script.name)
      assert description == "the #{segment} script"
      assert {:ok, %{"pong" => true}} = Scripts.run(script.name, "ping", %{})
    end
  end

  describe "create/1" do
    test "stores an accepted row and compiles it into the VM" do
      segment = segment()
      script = create!(segment)

      assert script.name == Macro.underscore(segment)
      assert script.origin == "authored"
      assert script.code_hash == script.accepted_hash
      assert script.accepted_at != nil
      assert Script.accepted?(script)
      assert %{loaded?: true} = Loader.facts(script.name)
    end

    test "writes the declarations string-keyed, the shape a re-read row has" do
      segment = segment()

      declarations = """
      %{
        hosts: ["Example.TEST"],
        url_action: :fetch,
        secrets: ["K"],
        throttles: %{"acct" => %{rate: 60, burst: 2, breaker: %{threshold: 2, cooldown: 500}}}
      }
      """

      script = create!(segment, declarations)

      expected = %{
        "hosts" => ["example.test"],
        "url_action" => "fetch",
        "secrets" => ["K"],
        "throttles" => %{
          "acct" => %{
            "rate" => 60,
            "burst" => 2,
            "breaker" => %{"threshold" => 2, "cooldown" => 500}
          }
        }
      }

      assert script.declarations == expected
      assert Repo.get!(Script, script.id).declarations == expected
    end

    test "refuses a name that already exists, pointing at update" do
      segment = segment()
      create!(segment)

      assert {:error, {:name_taken, message}} = Scripts.create(code(segment))
      assert message =~ "update it instead"
      assert Repo.aggregate(Script, :count) == 1
    end

    test "refuses a name that is a built-in reference source" do
      assert {:error, {:reserved_name, message}} = Scripts.create(code("Web"))
      assert message =~ "built-in reference source"
      assert Repo.aggregate(Script, :count) == 0
    end

    test "refuses a host an accepted script already claims" do
      claimed = ~s|%{hosts: ["hex.pm"], url_action: :fetch, secrets: []}|
      create!(segment(), claimed)

      other = segment()
      purge_on_exit(other)

      assert {:error, {:host_claimed, message}} = Scripts.create(code(other, claimed))
      assert message =~ "hex.pm is already claimed"
      assert Repo.aggregate(Script, :count) == 1
    end

    @tag doc: """
         Two writes claiming one host, released together. The host rule reads
         the accepted rows, and a rule that ran in each caller after the loader
         answered could see the other's row not yet stored and let both land —
         the silent loser the rule exists to prevent. The loader is held by a
         slow check so both writes queue behind it; the rule and the row write
         run inside each write's own message, so the second reads the first's
         row. Exactly one lands. The pre-fix red is a race rather than a
         certainty — this case is the guard, not the proof.
         """
    test "of two writes claiming one host, exactly one lands" do
      claimed = ~s|%{hosts: ["hex.pm"], url_action: :fetch, secrets: []}|
      slow = segment()
      purge_on_exit(slow)
      check = Task.async(fn -> Scripts.check(slow_code(slow)) end)
      Process.sleep(100)

      segments = [segment(), segment()]
      Enum.each(segments, &purge_on_exit/1)
      writes = for s <- segments, do: Task.async(fn -> Scripts.create(code(s, claimed)) end)

      results = Task.await_many(writes, 5_000)
      assert {:ok, _checked} = Task.await(check, 5_000)

      assert Enum.count(results, &match?({:ok, %Script{}}, &1)) == 1
      assert Enum.count(results, &match?({:error, {:host_claimed, _}}, &1)) == 1
      assert Repo.aggregate(Script, :count) == 1
    end

    test "lets a second script claim a host the first only declared unaccepted" do
      first = create!(segment(), ~s|%{hosts: ["hex.pm"], url_action: :fetch, secrets: []}|)

      first
      |> Script.changeset(%{accepted_hash: Script.hash("not this code")})
      |> Repo.update!()

      second = segment()
      purge_on_exit(second)

      assert {:ok, _script} =
               Scripts.create(
                 code(second, ~s|%{hosts: ["hex.pm"], url_action: :fetch, secrets: []}|)
               )
    end

    test "refuses a throttle an accepted script declares with other parameters, naming it" do
      first = create!(segment(), throttled("acct", "rate: 60, burst: 2"))

      other = segment()
      purge_on_exit(other)

      assert {:error, {:throttle_conflict, message}} =
               Scripts.create(code(other, throttled("acct", "rate: 60, burst: 3")))

      assert message ==
               "acct is declared by the accepted script #{first.name} with other parameters"

      assert Repo.aggregate(Script, :count) == 1
    end

    test "lets a second script declare a throttle with the same parameters" do
      create!(segment(), throttled("acct", "rate: 60, burst: 2"))

      assert %Script{} = create!(segment(), throttled("acct", "rate: 60, burst: 2"))
      assert Repo.aggregate(Script, :count) == 2
    end

    test "refuses code that will not compile and stores nothing" do
      assert {:error, {:syntax_error, _detail}} =
               Scripts.create("defmodule Script.X do\n  1 +\nend\n")

      assert Repo.aggregate(Script, :count) == 0
    end
  end

  describe "update/2" do
    test "replaces the code and keeps it accepted" do
      segment = segment()
      script = create!(segment)
      replacement = String.replace(code(segment), "the #{segment} script", "reworded")

      assert {:ok, updated} = Scripts.update(script.name, replacement)
      assert updated.description == "reworded"
      assert updated.code_hash == updated.accepted_hash
      assert updated.code_hash != script.code_hash
      assert Repo.aggregate(Script, :count) == 1
    end

    test "stamps an imported script authored, the door of its latest write" do
      segment = segment()
      purge_on_exit(segment)
      assert {:ok, imported} = Scripts.import(code(segment))
      replacement = String.replace(code(segment), "the #{segment} script", "reworded")

      assert {:ok, updated} = Scripts.update(imported.name, replacement)
      assert updated.origin == "authored"
    end

    test "refuses code whose derived name is not this script's" do
      segment = segment()
      script = create!(segment)
      other = segment()
      purge_on_exit(other)

      assert {:error, {:name_mismatch, message}} = Scripts.update(script.name, code(other))
      assert message =~ "to rename it"
    end

    test "refuses a script that is not there" do
      assert {:error, {:not_found, _detail}} = Scripts.update("absent", code(segment()))
    end

    test "changes the parameters of a throttle no other accepted script declares" do
      segment = segment()
      script = create!(segment, throttled("acct", "rate: 60, burst: 2"))
      replacement = code(segment, throttled("acct", "rate: 30, burst: 1"))

      assert {:ok, updated} = Scripts.update(script.name, replacement)
      assert updated.declarations["throttles"] == %{"acct" => %{"rate" => 30, "burst" => 1}}
    end

    @tag doc: """
         The invariant the in-flight registry exists for, from the write's side.
         A write lands by purging the module the run is executing inside, and a
         purge kills that process outright — with whatever it had already done
         outside this node left standing and no one told. A failure here means
         an update can take a run out from under its caller.
         """
    test "refuses an update while a run of that script is in flight" do
      script = napping!(segment())
      run = Task.async(fn -> Scripts.run(script.name, "naps", %{}) end)

      assert wait_until(fn -> Runner.in_flight?(script.name) end)

      assert {:error, {:run_in_flight, message}} = Scripts.update(script.name, script.code)
      assert message =~ script.name

      assert {:ok, %{"slept" => true}} = Task.await(run)
    end

    @tag doc: """
         The refusal the LOADER makes — a run that registered after the door's
         own look and before the loader's message — compiled nothing, so a
         restore there has nothing to put back, and its compile would purge the
         very tree that run is executing. The fixture mails this process from
         its module body on every compile, which is what makes a restore's
         compile visible; the loader is held busy by a slow check so the run
         can register in the gap between the door and the loader. A `:compiled`
         message arriving after the refusal means the restore ran.
         """
    test "a refusal the loader makes leaves the live tree alone" do
      segment = segment()
      mailbox = :"scripts_test_#{segment}"
      Process.register(self(), mailbox)
      script = napping!(segment, mailbox)
      assert_received :compiled

      slow = segment()
      purge_on_exit(slow)
      check = Task.async(fn -> Scripts.check(slow_code(slow)) end)
      Process.sleep(100)

      update = Task.async(fn -> Scripts.update(script.name, script.code) end)
      Process.sleep(100)

      run = Task.async(fn -> Scripts.run(script.name, "naps", %{}) end)
      assert wait_until(fn -> Runner.in_flight?(script.name) end)

      assert {:error, {:run_in_flight, _message}} = Task.await(update, 5_000)
      assert {:ok, %{"slept" => true}} = Task.await(run, 5_000)
      assert {:ok, _checked} = Task.await(check, 5_000)

      refute_received :compiled
      assert %{loaded?: true} = Loader.facts(script.name)
    end

    test "leaves the stored script loaded when the write is refused" do
      claimed = ~s|%{hosts: ["hex.pm"], url_action: :fetch, secrets: []}|
      create!(segment(), claimed)

      segment = segment()
      script = create!(segment)

      intruder =
        String.replace(code(segment, claimed), "the #{segment} script", "the intruder")

      assert {:error, {:host_claimed, _message}} = Scripts.update(script.name, intruder)
      assert Repo.get!(Script, script.id).code == script.code

      # The refused compile had already replaced the loaded module. Asking the
      # module itself is what proves the STORED code is what came back — the
      # loader's facts were never overwritten, so they look right either way.
      loaded = Module.concat(["Script", segment])
      assert loaded.description() == "the #{segment} script"

      assert %{loaded?: true, declarations: %{hosts: []}} = Loader.facts(script.name)
      assert {:ok, %{"pong" => true}} = Scripts.run(script.name, "ping", %{})
    end

    @tag doc: """
         The window the loader's one message closes, from the run's side. A
         write refused AFTER its compile — the host rule — has already replaced
         the stored tree with the candidate's, and a run asking for the module
         in that gap was once handed the candidate: code the node was in the
         act of refusing, executed under the script's name. The candidate holds
         the loader inside its own compile, which is what lets the run register
         and queue behind it; the answer it gets is the STORED code's, because
         the compile, the refusal and the restore are one message and the
         run's read waits for all three. Red before the change: the run
         answered the candidate's "pong".
         """
    test "a run released during a refused write executes the stored code, never the candidate" do
      claimed = ~s|%{hosts: ["hex.pm"], url_action: :fetch, secrets: []}|
      create!(segment(), claimed)

      segment = segment()
      script = create!(segment)

      # The stored fixture with a slow body, a host claim, and a different
      # answer — so that what the run answers says whose code it executed.
      candidate =
        String.replace(
          slow_code(segment, claimed),
          ~s|%{"pong" => true}|,
          ~s|%{"pong" => "candidate"}|
        )

      update = Task.async(fn -> Scripts.update(script.name, candidate) end)
      Process.sleep(100)

      run = Task.async(fn -> Scripts.run(script.name, "ping", %{}) end)
      assert wait_until(fn -> Runner.in_flight?(script.name) end)

      assert {:error, {:host_claimed, _message}} = Task.await(update, 5_000)
      assert {:ok, %{"pong" => true}} = Task.await(run, 5_000)
      assert Repo.get!(Script, script.id).code == script.code
    end

    @tag doc: """
         The row is read again inside the loader's message. An update whose row
         was removed while it queued must answer `not_found`, not re-create the
         row from the pre-image its door read — the operator who removed it
         would otherwise find it back, with no signal. The loader is held by a
         slow check so the delete lands between the door's look and the commit.
         """
    test "answers not_found when the row was removed while the update queued" do
      segment = segment()
      script = create!(segment)
      slow = segment()
      purge_on_exit(slow)
      check = Task.async(fn -> Scripts.check(slow_code(slow)) end)
      Process.sleep(100)

      update = Task.async(fn -> Scripts.update(script.name, script.code) end)
      Process.sleep(100)
      Repo.delete_all(from s in Script, where: s.id == ^script.id)

      assert {:error, {:not_found, _detail}} = Task.await(update, 5_000)
      assert {:ok, _checked} = Task.await(check, 5_000)
      assert Repo.aggregate(Script, :count) == 0
      assert Loader.facts(script.name) == nil
      refute Code.ensure_loaded?(Module.concat(["Script", segment]))
    end
  end

  describe "import/1" do
    test "creates when the name is free, with origin imported" do
      segment = segment()
      purge_on_exit(segment)

      assert {:ok, script} = Scripts.import(code(segment))
      assert script.origin == "imported"
    end

    test "replaces when the name is taken" do
      segment = segment()
      create!(segment)

      assert {:ok, imported} =
               Scripts.import(String.replace(code(segment), "script\"", "file\""))

      assert imported.origin == "imported"
      assert imported.description == "the #{segment} file"
      assert Repo.aggregate(Script, :count) == 1
    end

    @tag doc: """
         A replace that landed a second spelling of one name would put a second
         tree under one row and orphan the first — nothing would purge it,
         because every later purge parses the STORED code, which would then be
         the second. Refusing keeps one name one tree, and it is asserted at
         both replacing doors; why two spellings share a name is
         `YmerNode.Scripts`'s moduledoc.
         """
    test "refuses code whose top module differs from the stored one under that name" do
      base = "Case#{System.unique_integer([:positive])}"
      stored = create!(base <> "Api")
      upper = base <> "API"
      purge_on_exit(upper)

      assert Macro.underscore(upper) == stored.name

      assert {:error, {:module_mismatch, message}} = Scripts.import(code(upper))
      assert message =~ "remove #{stored.name}"
      assert {:error, {:module_mismatch, _message}} = Scripts.update(stored.name, code(upper))

      assert Repo.get_by!(Script, name: stored.name).code == stored.code
      assert Code.ensure_loaded?(Module.concat(["Script", base <> "Api"]))
      refute Code.ensure_loaded?(Module.concat(["Script", upper]))
    end
  end

  describe "plant_example/0" do
    setup do
      # The example's tree is compiled through the same path the migration
      # takes and purged by it; this covers a case that fails before the purge.
      purge_on_exit("Hex")
      :ok
    end

    test "plants the example as an accepted row of origin shipped" do
      assert {:ok, script} = Scripts.plant_example()

      assert script.name == "hex"
      assert script.origin == "shipped"
      assert Script.accepted?(script)
      assert script.contract == YmerNode.Script.contract()
      assert script.code == File.read!(Scripts.example_path())
      assert script.description =~ "hex.pm"

      assert script.declarations == %{
               "hosts" => ["hex.pm"],
               "url_action" => "fetch",
               "secrets" => [],
               "throttles" => %{}
             }
    end

    @tag doc: """
         Plant-once is what lets a removal stick: the migration that calls this
         runs once per node database, and this function must not be the thing
         that plants twice inside it. A failure means two rows of one name, or
         an operator's own copy overwritten by the build's.
         """
    test "plants once, and answers the row already there on a second call" do
      assert {:ok, planted} = Scripts.plant_example()
      assert {:ok, again} = Scripts.plant_example()

      assert again.id == planted.id
      assert Repo.aggregate(Script, :count) == 1
    end

    test "keeps an operator's own row of that name untouched" do
      assert {:ok, imported} = Scripts.import(File.read!(Scripts.example_path()))
      assert imported.origin == "imported"

      assert {:ok, kept} = Scripts.plant_example()
      assert kept.id == imported.id
      assert kept.origin == "imported"
    end

    @tag doc: """
         The host rule at the build's door, the one door that compiles outside
         the loader's message. A failure means a new build lands a second
         accepted script claiming the example's host beside an operator's own —
         the silent loser the rule exists to refuse — or that the refusal left
         the example's tree loaded for the loader to meet.
         """
    test "refuses a host an accepted script already claims, and plants nothing" do
      claimed = ~s|%{hosts: ["hex.pm"], url_action: :fetch, secrets: []}|
      claimant = create!(segment(), claimed)

      assert {:error, {:host_claimed, message}} = Scripts.plant_example()
      assert message =~ "hex.pm is already claimed by the accepted script #{claimant.name}"

      assert Repo.get_by(Script, name: "hex") == nil
      assert Repo.get!(Script, claimant.id).code == claimant.code
      assert Repo.aggregate(Script, :count) == 1
      refute Code.ensure_loaded?(Module.concat(["Script", "Hex"]))
    end

    test "leaves no tree behind for the loader to meet" do
      assert {:ok, _script} = Scripts.plant_example()
      refute Code.ensure_loaded?(Module.concat(["Script", "Hex"]))
    end

    test "the planted row is removed like any other" do
      assert {:ok, planted} = Scripts.plant_example()
      assert {:ok, _removed} = Scripts.remove(planted.name)
      assert {:error, {:not_found, _detail}} = Scripts.get(planted.name)
    end
  end

  describe "accept/1" do
    test "marks stale code accepted again" do
      segment = segment()
      script = create!(segment)

      stale =
        script
        |> Script.changeset(%{accepted_hash: Script.hash("something else")})
        |> Repo.update!()

      refute Script.accepted?(stale)

      assert {:ok, accepted} = Scripts.accept(stale.name)
      assert Script.accepted?(accepted)
    end

    @tag doc: """
         "Success, nothing changes" has to hold in the VM and not only in the
         row. Accepting recompiles on the stale path, and a recompile purges the
         module a run may be inside — so an accept that compiled unconditionally
         would let a defensive re-affirmation kill a live run. Unloading the
         module first is what makes the absence of a compile visible: an accept
         that compiled would put it back.
         """
    test "accepting an already-accepted script changes nothing" do
      segment = segment()
      script = create!(segment)
      module = Module.concat(["Script", segment])

      assert :ok = Loader.unload(script.name, module)
      refute Code.ensure_loaded?(module)

      assert {:ok, accepted} = Scripts.accept(script.name)
      assert accepted.accepted_at == script.accepted_at
      assert accepted.accepted_hash == script.accepted_hash
      refute Code.ensure_loaded?(module)
    end
  end

  describe "remove/1" do
    test "deletes the row and unloads the tree" do
      segment = segment()
      script = create!(segment)
      module = Module.concat(["Script", segment])

      assert Code.ensure_loaded?(module)
      assert {:ok, _removed} = Scripts.remove(script.name)
      assert Repo.aggregate(Script, :count) == 0
      refute Code.ensure_loaded?(module)
      assert Loader.facts(script.name) == nil
    end

    test "refuses a script that is not there" do
      assert {:error, {:not_found, _detail}} = Scripts.remove("absent")
    end

    @tag doc: """
         The row delete rides the unload's message. A remove and an update of
         one script released together must leave either the update's row with
         its tree, or no row and no tree — never a tree and facts with no row
         behind them, which nothing but a later write of that name could ever
         clear. The loader is held by a slow check so both queue; the remove's
         message runs first and the update's finds what it left. The pre-fix
         red is a race rather than a certainty — this case is the guard.
         """
    test "a remove and an update released together never leave a tree without a row" do
      segment = segment()
      script = create!(segment)
      slow = segment()
      purge_on_exit(slow)
      check = Task.async(fn -> Scripts.check(slow_code(slow)) end)
      Process.sleep(100)

      remove = Task.async(fn -> Scripts.remove(script.name) end)
      Process.sleep(50)
      update = Task.async(fn -> Scripts.update(script.name, script.code) end)

      assert {:ok, _removed} = Task.await(remove, 5_000)
      assert {:error, {:not_found, _detail}} = Task.await(update, 5_000)
      assert {:ok, _checked} = Task.await(check, 5_000)

      assert Repo.aggregate(Script, :count) == 0
      assert Loader.facts(script.name) == nil
      refute Code.ensure_loaded?(Module.concat(["Script", segment]))
    end

    test "refuses a remove while a run of that script is in flight, and keeps the row" do
      script = napping!(segment())
      run = Task.async(fn -> Scripts.run(script.name, "naps", %{}) end)

      assert wait_until(fn -> Runner.in_flight?(script.name) end)

      assert {:error, {:run_in_flight, _message}} = Scripts.remove(script.name)
      assert Repo.aggregate(Script, :count) == 1

      assert {:ok, %{"slept" => true}} = Task.await(run)
    end
  end

  describe "list/0" do
    test "answers one slim entry per row, by name" do
      first = create!("Aaa#{System.unique_integer([:positive])}")
      second = create!("Zzz#{System.unique_integer([:positive])}")

      assert [one, two] = Scripts.list()
      assert [one.name, two.name] == Enum.sort([first.name, second.name])
      assert one.actions == [:fetch, :ping]
      assert one.accepted?
      assert one.loaded?
      refute Map.has_key?(one, :code)
    end

    test "flags a row this boot never compiled instead of hiding it" do
      %Script{}
      |> Script.changeset(row_attrs("never_compiled_#{System.unique_integer([:positive])}"))
      |> Repo.insert!()

      assert [entry] = Scripts.list()
      refute entry.loaded?
      assert entry.actions == []
      assert {:not_compiled, _detail} = entry.error
    end
  end

  describe "describe/2" do
    test "leaves the code out unless it is asked for" do
      segment = segment()
      script = create!(segment)

      assert {:ok, without} = Scripts.describe(script.name)
      assert without.code == nil
      assert without.contract == 1
      assert %{fetch: %{write: false}} = without.actions

      assert without.declarations == %{
               "hosts" => [],
               "url_action" => nil,
               "secrets" => [],
               "throttles" => %{}
             }

      assert {:ok, with_code} = Scripts.describe(script.name, code: true)
      assert with_code.code == code(segment)
    end

    test "refuses a script that is not there" do
      assert {:error, {:not_found, _detail}} = Scripts.describe("absent")
    end
  end

  describe "run/3" do
    test "runs an accepted script's action" do
      script = create!(segment())

      assert {:ok, %{"pong" => true}} = Scripts.run(script.name, "ping", %{})
    end

    test "refuses to run code whose accepted hash is stale — the acceptance invariant" do
      script = create!(segment())

      stale =
        script
        |> Script.changeset(%{accepted_hash: Script.hash("code nobody stored")})
        |> Repo.update!()

      assert {:error, {:not_accepted, message}} = Scripts.run(stale.name, "ping", %{})
      assert message =~ "accept it before running it"
    end

    test "refuses a script that is not there" do
      assert {:error, {:not_found, _detail}} = Scripts.run("absent", "ping", %{})
    end

    @tag :tmp_dir
    @tag doc: """
         The one thing a caller cannot work out for itself. A script may declare
         several secrets, and a run that answered a bare "not found" would leave
         whoever called it reading the script's code to learn which of them was
         missing and then guessing the verb that sets it. Both halves are
         asserted because either alone is useless: the name without the verb, or
         the verb without the name.
         """
    test "a declared secret nobody set names the secret and the verb that sets it", %{
      tmp_dir: tmp_dir
    } do
      saved = Application.get_env(:ymer_node, Secrets)
      Application.put_env(:ymer_node, Secrets, path: Path.join(tmp_dir, "secrets.env"))
      on_exit(fn -> if saved, do: Application.put_env(:ymer_node, Secrets, saved) end)

      script = needs_secret!(segment())

      assert {:error, {:script_error, message}} = Scripts.run(script.name, "read", %{})
      assert message =~ "TOKEN"
      assert message =~ "secrets set TOKEN"
    end

    test "a throttle's refusal names the script, the action and the throttle" do
      script = unthrottled!(segment())

      assert {:error, {:script_error, message}} = Scripts.run(script.name, "read", %{})

      assert message ==
               "#{script.name} read: the script asked for the throttle absent, which its " <>
                 "declarations/0 does not name — declare it and accept the code again"
    end
  end

  defp segment, do: "Ctx#{System.unique_integer([:positive])}"

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() ->
        true

      attempts == 0 ->
        false

      true ->
        Process.sleep(10)
        wait_until(fun, attempts - 1)
    end
  end

  defp purge_on_exit(segment) do
    on_exit(fn -> Compiler.purge(Module.concat(["Script", segment])) end)
  end

  # A fixture that is not `code/2`, because every other case counts that one's
  # actions and reads its description: it naps, so a run of it can be in flight
  # while a case writes. Given a `mailbox`, it mails it from its module body on
  # every compile, so a case can see a compile it never asked for.
  defp napping!(segment, mailbox \\ nil) do
    purge_on_exit(segment)
    counting = if mailbox, do: "send(#{inspect(mailbox)}, :compiled)", else: ""

    code = """
    defmodule Script.#{segment} do
      use YmerNode.Script

      #{counting}

      @impl true
      def description, do: "sleeps, briefly"

      @impl true
      def actions do
        %{naps: %{description: "sleeps", properties: %{}, write: false, timeout: 5_000}}
      end

      @impl true
      def declarations, do: %{hosts: [], url_action: nil, secrets: []}

      @impl true
      def run(:naps, _args, _context) do
        Process.sleep(300)
        {:ok, %{"slept" => true}}
      end
    end
    """

    assert {:ok, script} = Scripts.create(code)
    script
  end

  # `code/2` with a body that holds the loader for half a second: a module body
  # runs while it compiles, and the compile happens inside the loader's one
  # message.
  defp slow_code(segment, declarations \\ "%{hosts: [], url_action: nil, secrets: []}") do
    String.replace(
      code(segment, declarations),
      "use YmerNode.Script\n",
      "use YmerNode.Script\n\n  Process.sleep(500)\n"
    )
  end

  defp needs_secret!(segment) do
    purge_on_exit(segment)

    code = """
    defmodule Script.#{segment} do
      use YmerNode.Script

      alias YmerNode.Script.Context

      @impl true
      def description, do: "reads one secret"

      @impl true
      def actions, do: %{read: %{description: "reads the token", properties: %{}, write: false}}

      @impl true
      def declarations, do: %{hosts: [], url_action: nil, secrets: ["TOKEN"]}

      @impl true
      def run(:read, _args, context), do: Context.secret(context, "TOKEN")
    end
    """

    assert {:ok, script} = Scripts.create(code)
    script
  end

  defp unthrottled!(segment) do
    purge_on_exit(segment)

    code = """
    defmodule Script.#{segment} do
      use YmerNode.Script

      alias YmerNode.Script.Context

      @impl true
      def description, do: "asks for a throttle it never declared"

      @impl true
      def actions, do: %{read: %{description: "reads a page", properties: %{}, write: false}}

      @impl true
      def declarations, do: %{hosts: [], url_action: nil, secrets: []}

      @impl true
      def run(:read, _args, context) do
        Context.request(context, url: "https://example.test/", throttle: "absent")
      end
    end
    """

    assert {:ok, script} = Scripts.create(code)
    script
  end

  # Declarations naming one throttle, for `code/2` and `create!/2`.
  defp throttled(name, parameters) do
    ~s|%{hosts: [], url_action: nil, secrets: [], throttles: %{"#{name}" => %{#{parameters}}}}|
  end

  defp create!(segment, declarations \\ "%{hosts: [], url_action: nil, secrets: []}") do
    purge_on_exit(segment)

    assert {:ok, script} = Scripts.create(code(segment, declarations))
    script
  end

  defp code(segment, declarations \\ "%{hosts: [], url_action: nil, secrets: []}") do
    """
    defmodule Script.#{segment} do
      use YmerNode.Script

      @impl true
      def description, do: "the #{segment} script"

      @impl true
      def actions do
        %{
          fetch: %{
            description: "fetches a url",
            properties: %{"url" => %{"type" => "string"}},
            required: ["url"],
            write: false
          },
          ping: %{description: "answers", properties: %{}, write: false}
        }
      end

      @impl true
      def declarations, do: #{declarations}

      @impl true
      def run(:ping, _args, _context), do: {:ok, %{"pong" => true}}
      def run(:fetch, %{"url" => url}, _context), do: {:ok, %{"url" => url}}
    end
    """
  end

  defp row_attrs(name) do
    code = "defmodule Script.Absent do\nend\n"

    %{
      name: name,
      code: code,
      code_hash: Script.hash(code),
      accepted_hash: Script.hash(code),
      accepted_at: DateTime.utc_now() |> DateTime.truncate(:second),
      origin: "authored",
      contract: 1,
      description: name,
      declarations: %{"hosts" => [], "url_action" => nil, "secrets" => []}
    }
  end
end
