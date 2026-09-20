defmodule YmerNode.Scripts.LoaderTest do
  @moduledoc """
  These cases start the loader themselves when nothing else has, so the file
  stands on its own: it needs no supervision tree around it and no application
  config, which is what lets it be written and run before the loader is wired
  into anything. Where the tree *has* started one — every run of the whole
  suite — the setup finds it and talks to that one, because a second process
  under the same name would not start.

  Every fixture takes a unique name (`YmerNode.ScriptCase` is not used here
  because these cases need `YmerNode.Repo`'s sandbox), and each unloads its own
  tree on exit.

  The boot path is exercised by calling `boot_compile/0` directly, with the
  boot-time call turned off — by `start_link/1`'s own option here, by
  `config/test.exs` where the tree starts it — for the same reason the vector
  probe is off in tests: the sandbox holds no checked-out connection at
  application start.

  Not async: `YmerNode.DataCase` owns a sandbox this adapter cannot share, and
  the loader's state is one process's.
  """
  use YmerNode.DataCase

  alias YmerNode.Scripts.Compiler
  alias YmerNode.Scripts.Loader
  alias YmerNode.Scripts.Script

  setup do
    if is_nil(Process.whereis(Loader)), do: start_supervised!({Loader, boot_compile: false})
    :ok
  end

  defp fixture(overrides \\ %{}) do
    segment = "Loaded#{System.unique_integer([:positive])}"
    name = Macro.underscore(segment)
    module = Module.concat(["Script", segment])

    code =
      Map.get(
        overrides,
        :code,
        """
        defmodule Script.#{segment} do
          use YmerNode.Script

          @impl true
          def description, do: "#{name}"

          @impl true
          def actions, do: %{noop: %{description: "n", properties: %{}, write: false}}

          @impl true
          def declarations, do: %{hosts: [], url_action: nil, secrets: []}

          @impl true
          def run(:noop, _args, _context), do: {:ok, %{}}
        end
        """
      )

    on_exit(fn -> Compiler.purge(module) end)
    %{code: code, name: name, module: module, segment: segment}
  end

  defp insert!(fixture, overrides \\ %{}) do
    code = Map.get(overrides, :code, fixture.code)

    attrs =
      %{
        name: fixture.name,
        code: code,
        code_hash: Script.hash(code),
        accepted_hash: Script.hash(code),
        accepted_at: DateTime.utc_now() |> DateTime.truncate(:second),
        origin: "authored",
        contract: 1,
        description: fixture.name,
        declarations: %{"hosts" => [], "url_action" => nil, "secrets" => []}
      }
      |> Map.merge(overrides)

    %Script{} |> Script.changeset(attrs) |> Repo.insert!()
  end

  describe "load/1" do
    test "compiles and records what the tree defined" do
      fixture = fixture()

      assert {:ok, compiled} = Loader.load(fixture.code)
      assert compiled.name == fixture.name

      assert %{loaded?: true, module: module, modules: [_ | _], warnings: [], error: nil} =
               Loader.facts(fixture.name)

      assert module == fixture.module
    end

    test "keeps the metadata the compiler read, so a listing needs no script code" do
      fixture = fixture()

      assert {:ok, _compiled} = Loader.load(fixture.code)

      facts = Loader.facts(fixture.name)
      assert facts.contract == 1
      assert facts.description == fixture.name
      assert %{noop: %{description: "n", properties: %{}, write: false}} = facts.actions
      assert facts.declarations == %{hosts: [], url_action: nil, secrets: [], throttles: %{}}
    end

    test "refuses code that will not compile and goes on answering" do
      assert {:error, {:module_outside_script, _}} = Loader.load("defmodule Enum do\nend\n")
      assert Process.alive?(Process.whereis(Loader))
      assert Loader.all_facts() |> is_map()
    end

    @tag doc: """
         A module body can end the compile task by an exit SIGNAL — a
         `spawn_link` whose process exits — which no `try` inside the task can
         catch. Linked to the loader, that signal took the loader down, every
         script's facts with it, and at boot the node's start; the task runs
         under the supervisor instead, so the death arrives as a refusal and
         the loader is the same process afterwards.
         """
    test "a linked process dying in the module body is a refusal, not the loader's death" do
      fixture = fixture()
      loader = Process.whereis(Loader)

      code =
        String.replace(
          fixture.code,
          "use YmerNode.Script\n",
          "use YmerNode.Script\n\n  spawn_link(fn -> exit(:boom) end)\n  Process.sleep(50)\n"
        )

      assert {:error, {:compile_error, detail}} = Loader.load(code)
      assert detail =~ "boom"
      assert Process.alive?(loader)
      assert Process.whereis(Loader) == loader
    end

    @tag doc: """
         A candidate that parses but fails to compile has already purged the
         tree of that name — the compiler purges first — so a load that
         recorded nothing on failure left the facts saying `loaded?` about a
         module that was gone, and the next run failed as `not_loaded` where
         `describe` still showed a healthy script. The stored row's code goes
         back inside the same message; asking the module itself is what proves
         it is the stored code, since the facts read right either way.
         """
    test "puts the stored code back when a candidate fails to compile" do
      fixture = fixture()
      insert!(fixture)
      assert {:ok, _compiled} = Loader.load(fixture.code)

      bare = "defmodule Script.#{fixture.segment} do\nend\n"
      assert {:error, {:missing_contract, _detail}} = Loader.load(bare)

      module = fixture.module
      assert module.description() == fixture.name
      assert %{loaded?: true, error: nil} = Loader.facts(fixture.name)
    end

    test "forgets a name with no row behind it when its candidate fails to compile" do
      fixture = fixture()
      assert {:ok, _compiled} = Loader.load(fixture.code)

      bare = "defmodule Script.#{fixture.segment} do\nend\n"
      assert {:error, {:missing_contract, _detail}} = Loader.load(bare)

      assert Loader.facts(fixture.name) == nil
      refute Code.ensure_loaded?(fixture.module)
    end
  end

  describe "load/2 with commit:" do
    test "runs the commit on the compiled candidate and answers its value" do
      fixture = fixture()

      assert {:ok, name} =
               Loader.load(fixture.code, commit: fn compiled -> {:ok, compiled.name} end)

      assert name == fixture.name
      assert %{loaded?: true} = Loader.facts(fixture.name)
    end

    @tag doc: """
         The refusal that closes a write's window: a commit that refuses has a
         compiled candidate in the VM under the stored script's name, and the
         restore runs before this call answers, so no reader is ever handed
         that candidate. Asked directly, the module is the stored code again,
         and the facts never recorded the candidate.
         """
    test "puts the stored code back and records nothing for a candidate the commit refuses" do
      fixture = fixture()
      insert!(fixture)
      assert {:ok, _compiled} = Loader.load(fixture.code)
      candidate = String.replace(fixture.code, ~s|"#{fixture.name}"|, ~s|"candidate"|)

      assert {:error, :refused} =
               Loader.load(candidate, commit: fn _compiled -> {:error, :refused} end)

      module = fixture.module
      assert module.description() == fixture.name
      assert %{loaded?: true, description: description} = Loader.facts(fixture.name)
      assert description == fixture.name
    end

    test "a commit that raises is a refusal, and the loader goes on answering" do
      fixture = fixture()
      insert!(fixture)
      assert {:ok, _compiled} = Loader.load(fixture.code)

      assert {:error, {:commit_failed, message}} =
               Loader.load(fixture.code, commit: fn _compiled -> raise "boom" end)

      assert message =~ "boom"
      assert Process.alive?(Process.whereis(Loader))
      assert %{loaded?: true} = Loader.facts(fixture.name)
    end
  end

  describe "unload/2" do
    test "purges the tree and forgets the facts" do
      fixture = fixture()
      assert {:ok, _} = Loader.load(fixture.code)
      assert Loader.facts(fixture.name)

      assert :ok = Loader.unload(fixture.name, fixture.module)
      assert Loader.facts(fixture.name) == nil
      refute Code.ensure_loaded?(fixture.module)
    end

    test "runs the commit inside the message and answers it, the tree and facts gone either way" do
      fixture = fixture()
      assert {:ok, _} = Loader.load(fixture.code)

      assert {:ok, :deleted} =
               Loader.unload(fixture.name, fixture.module, commit: fn -> {:ok, :deleted} end)

      assert Loader.facts(fixture.name) == nil
      refute Code.ensure_loaded?(fixture.module)

      assert {:ok, _} = Loader.load(fixture.code)

      assert {:error, :gone} =
               Loader.unload(fixture.name, fixture.module, commit: fn -> {:error, :gone} end)

      assert Loader.facts(fixture.name) == nil
      refute Code.ensure_loaded?(fixture.module)
    end
  end

  describe "boot_compile/0" do
    test "loads every accepted row and skips the unaccepted" do
      accepted = fixture()
      insert!(accepted)

      unaccepted = fixture()
      insert!(unaccepted, %{accepted_hash: nil, accepted_at: nil})

      assert %{loaded: loaded} = Loader.boot_compile()
      assert loaded >= 1
      assert %{loaded?: true} = Loader.facts(accepted.name)
      assert Loader.facts(unaccepted.name) == nil
    end

    @tag doc: """
         The rule that keeps one bad script from costing the node its notebook
         and its registry: a row that will not compile is kept, its diagnostics
         recorded, and the boot goes on. A failure means a stored script whose
         dependency moved — a node upgrade, a battery change — would stop the
         node from starting at all, and the operator would have no way in to fix
         the script.
         """
    test "keeps a row that will not compile, records why, and does not raise" do
      broken = fixture()
      good = fixture()

      insert!(broken, %{
        code: "defmodule Script.#{broken.segment} do\n  def a do\n    1 +\n  end\nend\n"
      })

      insert!(good)

      assert %{refused: refused} = Loader.boot_compile()
      assert refused >= 1

      facts = Loader.facts(broken.name)
      assert %{loaded?: false, module: nil, actions: %{}, error: {:syntax_error, _}} = facts

      # One shape either way, so a caller rendering a listing never branches on it.
      assert Map.keys(facts) == Map.keys(Loader.facts(good.name))
    end
  end

  describe "all_facts/0" do
    test "answers a map keyed by script name" do
      fixture = fixture()
      assert {:ok, _} = Loader.load(fixture.code)

      assert %{loaded?: true} = Map.fetch!(Loader.all_facts(), fixture.name)
    end
  end
end
