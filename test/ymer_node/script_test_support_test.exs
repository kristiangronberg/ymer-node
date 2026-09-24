defmodule YmerNode.ScriptTestSupportTest do
  @moduledoc """
  The node's application runs in this suite, so `start_run_tree/1` would find
  every process of the run tree already started: the cases call
  `fill_unset_config/0` — the configuration half of that setup — directly, and
  `mix ymer_node.consumer_check` proves the whole callback where no
  application runs.

  **Not async**: the layer writes VM-global application config — the
  `YmerNode.Script.Context` and `YmerNode.Secrets` entries — which
  `YmerNode.ScriptContextTest`, `YmerNode.SecretsTest` and
  `YmerNode.ScriptHarnessTest` set too. The setup puts both entries back as it
  found them on exit.

  The module is aliased as `ScriptTest`, because a bare `Test` reads as ExUnit's.
  """
  use ExUnit.Case, async: false

  alias YmerNode.Script.Context
  alias YmerNode.Script.Harness
  alias YmerNode.Script.Test, as: ScriptTest
  alias YmerNode.ScriptCase
  alias YmerNode.Secrets

  setup do
    saved = Harness.snapshot()
    on_exit(fn -> Harness.restore(saved) end)
    :ok
  end

  defp unset_every_key do
    config = Application.get_env(:ymer_node, Context, [])
    Application.put_env(:ymer_node, Context, Keyword.drop(config, [:request_options, :files_dir]))
    Application.delete_env(:ymer_node, Secrets)
  end

  defp tmp_path(name) do
    Path.expand(Path.join("tmp", "#{name}#{System.get_env("MIX_TEST_PARTITION", "")}"))
  end

  describe "fill_unset_config/0" do
    test "fills each unset key through the harness and creates the files directory" do
      unset_every_key()
      on_exit(fn -> File.rm_rf!(tmp_path("files")) end)

      assert :ok = ScriptTest.fill_unset_config()

      assert Keyword.get(Context.request_options(), :plug) == {Req.Test, Context}
      assert Secrets.path() == tmp_path("secrets") <> ".env"
      assert Context.files_dir(ScriptTest.context()) == tmp_path("files")
      assert File.dir?(tmp_path("files"))
    end

    @tag doc: """
         A key set to `nil` — `plug: nil`, or a path read from an environment
         variable that is unset — is unset. A failure on the plug means a test
         that forgot to stub reaches the real host, since Req reads `plug: nil`
         as no plug.
         """
    test "fills a key the configuration sets to nil" do
      config = Application.get_env(:ymer_node, Context, [])

      Application.put_env(
        :ymer_node,
        Context,
        Keyword.merge(config, request_options: [plug: nil], files_dir: nil)
      )

      Application.put_env(:ymer_node, Secrets, path: nil)
      on_exit(fn -> File.rm_rf!(tmp_path("files")) end)

      assert :ok = ScriptTest.fill_unset_config()

      assert Keyword.get(Context.request_options(), :plug) == {Req.Test, Context}
      assert Secrets.path() == tmp_path("secrets") <> ".env"
      assert Context.files_dir(ScriptTest.context()) == tmp_path("files")
    end

    @tag doc: """
         Req reads `plug: false` as no plug, as it reads `nil`. A failure means
         a test that forgot to stub reaches the real host.
         """
    test "stubs the request plug when the configuration sets it to false" do
      config = Application.get_env(:ymer_node, Context, [])
      Application.put_env(:ymer_node, Context, Keyword.put(config, :request_options, plug: false))

      assert :ok = ScriptTest.fill_unset_config()

      assert Keyword.get(Context.request_options(), :plug) == {Req.Test, Context}
    end

    @tag doc: """
         An interrupted run never reaches `put_secrets/1`'s removal, and
         `YmerNode.Secrets.set/2` merges into what it finds. A failure means a
         value the last run wrote reaches this one's tests.
         """
    test "removes the default secrets file an earlier run left behind" do
      default = tmp_path("secrets") <> ".env"
      File.mkdir_p!(Path.dirname(default))
      :ok = Harness.put_secrets_path(default)
      :ok = Secrets.set("STALE_PASSWORD", "stale")
      assert File.exists?(default)

      unset_every_key()
      on_exit(fn -> File.rm_rf!(tmp_path("files")) end)

      assert :ok = ScriptTest.fill_unset_config()

      refute File.exists?(default)
    end

    @tag doc: """
         A consumer's own configuration is the one a test must run under. A
         failure means the layer overwrote a key the application set — a
         consumer pointing its secrets file somewhere of its own would find
         its tests writing to the layer's instead. The plug is pointed first at
         `{Req.Test, :configured_stub}`, a value the layer never fills, because
         the suite's configuration names the one it does.
         """
    test "never replaces a key the configuration sets" do
      :ok = Harness.put_request_plug({Req.Test, :configured_stub})
      secrets_path = Secrets.path()
      files_dir = Context.files_dir(ScriptTest.context())

      assert :ok = ScriptTest.fill_unset_config()

      assert Keyword.get(Context.request_options(), :plug) == {Req.Test, :configured_stub}
      assert Secrets.path() == secrets_path
      assert Context.files_dir(ScriptTest.context()) == files_dir
    end

    @tag doc: """
         The check runs in an `on_exit` registered before the call, so it runs
         after the layer's own restore and before this module's setup puts the
         suite's configuration back — `on_exit` callbacks run in reverse order
         of registration. A failure means a key the layer filled outlived the
         test, and the next test would run under it without asking.
         """
    test "puts both entries back as it found them when the test ends" do
      unset_every_key()
      context_before = Application.get_env(:ymer_node, Context)

      on_exit(fn ->
        assert Application.get_env(:ymer_node, Context) == context_before
        assert Application.get_env(:ymer_node, Secrets) == nil
        File.rm_rf!(tmp_path("files"))
      end)

      assert :ok = ScriptTest.fill_unset_config()
    end
  end

  describe "put_secrets/1" do
    @tag doc: """
         Guards the one arrangement a live run and a test share a VM under: a
         live run points the secrets key at a real file, and a test writing
         through it would overwrite a real account's values and then remove
         the file. A failure means that write is possible again.
         """
    test "refuses before writing when the secrets file is outside the project's tmp/" do
      path = Secrets.path()
      before = File.read(path)

      assert_raise ArgumentError, ~r/writes only under/, fn ->
        ScriptTest.put_secrets(%{"PROBE_PASSWORD" => "probe"})
      end

      assert File.read(path) == before
    end

    test "writes the values 0600 under tmp/ and answers the file's path" do
      name = tmp_path("script_test_support_#{System.unique_integer([:positive])}_") <> ".env"
      :ok = Harness.put_secrets_path(name)

      path = ScriptTest.put_secrets(%{"PROBE_PASSWORD" => "probe"})

      assert path == Path.expand(name)
      assert Secrets.get("PROBE_PASSWORD") == {:ok, "probe"}
      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    end

    @tag doc: """
         The check is registered before the call, so it runs after the removal
         `put_secrets/1` registers — `on_exit` callbacks run in reverse order of
         registration. A failure means a test's secret values outlived it, and
         the next test pointed at the same file would read them.
         """
    test "removes the file once the test ends" do
      name = tmp_path("script_test_support_#{System.unique_integer([:positive])}_") <> ".env"
      :ok = Harness.put_secrets_path(name)
      expected_path = Path.expand(name)

      on_exit(fn -> refute File.exists?(expected_path) end)

      assert ScriptTest.put_secrets(%{"PROBE_PASSWORD" => "probe"}) == expected_path
    end
  end

  describe "compile_script/1" do
    @describetag :tmp_dir

    @tag doc: """
         The unload check is registered before the call, so it runs after the
         purge `compile_script/1` registers — `on_exit` callbacks run in reverse
         order of registration. A failure means the module tree outlived the
         test that compiled it.
         """
    test "compiles the file through the node's compiler", %{tmp_dir: tmp_dir} do
      fixture = ScriptCase.fixture()
      file = Path.join(tmp_dir, "fixture.exs")
      File.write!(file, fixture.code)
      on_exit(fn -> refute :code.is_loaded(fixture.module) end)

      compiled = ScriptTest.compile_script(file)

      assert compiled.module == fixture.module
      assert compiled.name == fixture.name
      assert compiled.module.run(:noop, %{}, ScriptTest.context()) == {:ok, %{}}
    end

    test "raises with the compiler's reason when the file does not compile", %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "broken.exs")
      File.write!(file, "defmodule Script.Broken do\n")

      assert_raise ArgumentError, ~r/broken\.exs does not compile/, fn ->
        ScriptTest.compile_script(file)
      end
    end
  end

  describe "context/1" do
    test "is shaped the way a run receives one, with 30 s to its deadline" do
      context = ScriptTest.context()
      now = System.monotonic_time(:millisecond)

      assert %Context{script: "test", action: :get, secrets: [], throttles: %{}} = context
      assert (context.deadline - now) in 29_000..30_000
    end

    test "takes the declared names, the throttles and a deadline of its own" do
      throttles = %{"probe" => %{rate: 60, burst: 2}}

      context =
        ScriptTest.context(
          script: "probe",
          action: :list,
          secrets: ["PROBE_PASSWORD"],
          throttles: throttles,
          deadline_ms: 1_000
        )

      now = System.monotonic_time(:millisecond)

      assert %Context{script: "probe", action: :list, secrets: ["PROBE_PASSWORD"]} = context
      assert context.throttles == throttles
      assert (context.deadline - now) in 0..1_000
    end
  end
end
