defmodule YmerNode.Script.Test do
  @moduledoc """
  Testing a script in a repository of its own: an ExUnit setup callback and
  the functions a script test calls, over `YmerNode.Script.Harness`. Nothing is
  `use`d — as with `Req.Test`, a test module names what it wants in `setup`.

  ## The recipe

  Take `ymer_node` as a dependency under `runtime: false`, and list `:req`
  among your own dependencies for runtime: a script's requests go through Req
  in the test VM, and without Req's application started a stubbed request
  exits with `:noproc`. One line of configuration stays yours, because no
  dependency can set it for the application that takes it:

      config :elixir, :time_zone_database, Tz.TimeZoneDatabase

  Without it every zone-aware `DateTime` call in a test answers
  `{:error, :utc_only_time_zone_database}`. Then, in each test module:

      use ExUnit.Case, async: false

      setup {YmerNode.Script.Test, :start_run_tree}

      test "reads one issue" do
        compiled = YmerNode.Script.Test.compile_script("scripts/jira.exs")
        YmerNode.Script.Test.put_secrets(%{"JIRA_PASSWORD" => "probe-password"})

        Req.Test.stub(YmerNode.Script.Context, fn conn ->
          Req.Test.json(conn, %{"key" => "X-1"})
        end)

        context = YmerNode.Script.Test.context(secrets: ["JIRA_PASSWORD"])

        assert {:ok, _issue} = compiled.module.run(:get, %{"key" => "X-1"}, context)
      end

  A script that declares libraries is compiled with their files, each library
  first, and its declarations are checked against their versions as acceptance
  checks them — no layout is imposed on the repository, so the paths are the
  test's to name:

      compiled =
        YmerNode.Script.Test.compile_script("scripts/jira.exs",
          libraries: ["libraries/crosskey.exs"]
        )

  A library is tested on its own with `compile_library/1`.

  ## `async: false`, and why

  Every test module using `start_run_tree/1` runs `async: false`. The run
  tree's names (`YmerNode.Script.Harness.run_tree/0`) are the node's own and
  VM-global, and so are the secrets file
  and the files directory: a second module overlapping a first would have
  `start_run_tree/1` raise — `ExUnit.Callbacks.start_supervised!/1` fails loudly
  on the name collision rather than returning a value — and would read a
  secrets file the first one's exit had just removed. Nothing enforces the
  flag — each test module writes it.

  ## What the setup fills in

  A key the application's configuration sets is never replaced. For a key it
  leaves unset — missing, or set to `nil`, and a plug set to `false`, which Req
  reads as no plug — `start_run_tree/1` puts one through
  the harness for the test, and puts the configuration back as it found it when
  the test ends:

    * the request plug — `{Req.Test, YmerNode.Script.Context}`, the name a test
      stubs under, so a test that forgets to stub meets Req.Test's own failure
      rather than the real host;
    * the secrets file — `tmp/secrets.env` under the directory the test run
      started in, removed at setup — `put_secrets/1` removes it again on
      exit — so nothing an interrupted run wrote there reaches the next test;
    * the files directory — `tmp/files` there, which the setup creates whether
      it filled the key or not, as the node creates its own at boot.

  Under `mix test --partitions`, each instance's `MIX_TEST_PARTITION` joins
  both names — `tmp/secrets2.env` and `tmp/files2` for the second — so no two
  instances share a file.
  """
  alias YmerNode.Script.Context
  alias YmerNode.Script.Harness
  alias YmerNode.Scripts.Compiler
  alias YmerNode.Scripts.Libraries
  alias YmerNode.Scripts.Runner
  alias YmerNode.Secrets

  @doc """
  Starts the run tree for this test and fills in the configuration a run reads
  where the application leaves it unset, § What the setup fills in above. Name
  it in `setup`: `setup {YmerNode.Script.Test, :start_run_tree}`.

  Per test, so each test gets a fresh throttle bucket and breaker: a throttle
  with a burst of two would otherwise queue a whole suite behind itself.
  """
  def start_run_tree(_context) do
    Enum.each(Harness.run_tree(), &ExUnit.Callbacks.start_supervised!/1)
    fill_unset_config()
  end

  @doc """
  Compiles the script file at `path` through the node's own compiler — the one
  that accepts a script into a node — and purges its module tree when the test
  ends, so what a test proves is that the file itself satisfies the contract.

  Answers the compiler's map — `module`, `name`, `declarations`, `actions` and
  the rest — and raises with the compiler's reason when the file does not
  compile.

  `libraries:` takes the paths of the libraries the script declares. Each is
  compiled first, through `compile_library/1`, and the script's declarations are
  then checked against their versions as acceptance checks them
  (`YmerNode.Scripts.Libraries.check_held/3`): a library the script declares and
  the list leaves out, or one at a version outside its requirement, raises with
  the refusal acceptance would give. A library's own path raises, pointing at
  `compile_library/1`. Every tree is purged when the test ends.
  """
  def compile_script(path, options \\ []) when is_binary(path) and is_list(options) do
    libraries = options |> Keyword.get(:libraries, []) |> Enum.map(&compile_library/1)

    compiled =
      case compile_file(path) do
        %{kind: :script} = compiled ->
          compiled

        %{kind: kind} ->
          raise ArgumentError, "#{path} is a #{kind}, test it with compile_library/1"
      end

    held = Map.new(libraries, &{&1.name, Map.merge(&1, %{loaded?: true, error: nil})})

    case Libraries.check_held(compiled.name, compiled.declarations.libraries, held) do
      :ok -> compiled
      {:error, reason} -> raise ArgumentError, "#{path} is refused: #{inspect(reason)}"
    end
  end

  @doc """
  Compiles the library file at `path` through the node's compiler and purges its
  module tree when the test ends, answering the compiler's map — its `module`,
  `name`, `version` and documented `api` among it. Raises when the file does not
  compile, or is not a library.
  """
  def compile_library(path) when is_binary(path) do
    case compile_file(path) do
      %{kind: :library} = compiled -> compiled
      %{kind: kind} -> raise ArgumentError, "#{path} is a #{kind}, not a library"
    end
  end

  defp compile_file(path) do
    case path |> File.read!() |> Compiler.compile() do
      {:ok, compiled} ->
        module = compiled.module
        ExUnit.Callbacks.on_exit(fn -> Compiler.purge(module) end)
        compiled

      {:error, reason} ->
        raise ArgumentError, "#{path} does not compile: #{inspect(reason)}"
    end
  end

  @doc """
  A `%YmerNode.Script.Context{}` shaped the way a run receives one.

  `secrets` takes the declared names — the values go to `put_secrets/1` — and
  `throttles` the declared throttles. The deadline is the runner's default of
  30 s from now, or `deadline_ms` from now when given.
  """
  def context(options \\ []) when is_list(options) do
    %Context{
      script: Keyword.get(options, :script, "test"),
      action: Keyword.get(options, :action, :get),
      secrets: Keyword.get(options, :secrets, []),
      throttles: Keyword.get(options, :throttles, %{}),
      deadline:
        System.monotonic_time(:millisecond) +
          Keyword.get_lazy(options, :deadline_ms, fn -> Runner.deadline(%{}) end)
    }
  end

  @doc """
  Writes `values`, a map of secret names to values, into the configured
  secrets file through the node's own `YmerNode.Secrets.set/2`, which creates
  it `0600`; the file is removed when the test ends. Answers the file's path.

  Raises before writing a byte when the file is not under the project's
  `tmp/` — a VM a live run pointed at a real secrets file, through
  `YmerNode.Script.Harness.put_secrets_path/1`, must never have that file
  overwritten with test values and then removed.
  """
  def put_secrets(values) when is_map(values) do
    path = Path.expand(Secrets.path())
    root = tmp_root()

    if not String.starts_with?(path, root <> "/") do
      raise ArgumentError,
            "put_secrets/1 writes only under #{root}, and the secrets path is #{path} — " <>
              "this VM is pointed at a real secrets file, which no test may write"
    end

    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(path) end)
    Enum.each(values, fn {name, value} -> :ok = Secrets.set(name, value) end)
    path
  end

  # Both owners' entries are put back whole, or deleted when they were unset,
  # through the harness that points their keys: a key filled here must not
  # outlive the test, and restoring the entry rather than the key keeps an
  # unset key unset.
  #
  # Public, and `@doc false`, ONLY so the node's own suite can run it: the
  # node's application is running there, so `start_run_tree/1` would find every
  # process of the run tree already started. `YmerNode.ScriptTestSupportTest`
  # is the caller.
  @doc false
  def fill_unset_config do
    saved = Harness.snapshot()
    ExUnit.Callbacks.on_exit(fn -> Harness.restore(saved) end)

    # Req reads `plug: false` as no plug, exactly as it reads `nil`.
    if Keyword.get(Context.request_options(), :plug) in [nil, false],
      do: Harness.put_request_plug({Req.Test, Context})

    if not Harness.configured?(Secrets, :path) do
      Harness.put_secrets_path(Path.join(tmp_root(), "secrets#{partition()}.env"))
      # The layer's own file: whatever an interrupted run left in it goes, or
      # `Secrets.set/2`'s merge would hand this test the last run's values.
      File.rm_rf!(Secrets.path())
    end

    if not Harness.configured?(Context, :files_dir),
      do: Harness.put_files_dir(Path.join(tmp_root(), "files#{partition()}"))

    context() |> Context.files_dir() |> File.mkdir_p!()
  end

  # The project is the directory the test run started in, which under Mix is
  # the project's root; nothing here calls Mix, so a VM without it runs this
  # the same way.
  defp tmp_root, do: Path.expand("tmp", File.cwd!())

  defp partition, do: System.get_env("MIX_TEST_PARTITION", "")
end
