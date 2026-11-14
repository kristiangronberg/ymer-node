defmodule YmerNode.Scripts.CompilerTest do
  @moduledoc """
  Compiles into this VM, so every fixture takes a name unique to its case and
  purges its own tree at teardown — `YmerNode.ScriptCase` owns both, which is
  what makes this module `async: true` despite the global module table.

  The parse cases compile nothing at all: that is the point of them. Refusing
  before the compile is what keeps a `defmodule Enum` from ever reaching the
  code server, so a failure in one of those cases is a security regression and
  not a naming quibble.
  """
  use YmerNode.ScriptCase, async: true

  alias YmerNode.Scripts.Compiler

  describe "parse/1 — the derived name" do
    test "derives the row's name from the top module's last segment" do
      for {segment, expected} <- [
            {"Hex", "hex"},
            {"Jira", "jira"},
            {"JIRA", "jira"},
            {"ReqTest", "req_test"},
            {"HTTPClient", "http_client"},
            {"V2Api", "v2_api"}
          ] do
        assert {:ok, %{name: ^expected, module: module}} =
                 Compiler.parse("defmodule Script.#{segment} do\nend\n")

        assert module == Module.concat(["Script", segment])
      end
    end
  end

  describe "parse/1 — the module-tree rule" do
    @tag doc: """
         The rule that keeps a script from replacing the standard library or the
         node's own modules. A failure means code defining `Enum` or
         `YmerNode.Repo` would reach the compiler, and a compile is not
         reversible: the replacement is live for every process in the node
         until it restarts. Read the refusals here before relaxing any of them.
         """
    test "refuses a top-level module outside Script." do
      for code <- [
            "defmodule Enum do\nend\n",
            "defmodule YmerNode.Repo do\nend\n",
            "defmodule Script do\nend\n",
            "defmodule Script.Jira.Client do\nend\n"
          ] do
        assert {:error, {:module_outside_script, _detail}} = Compiler.parse(code)
      end
    end

    @tag doc: """
         The escape. `defmodule Elixir.Enum` nested inside `Script.Hex` is NOT
         scoped by its parent: compiling that string defines a top-level `Enum`,
         measured on this toolchain. A failure means a nested absolute alias
         stopped being seen, and the tree rule has a hole a reader of the top
         module would never spot.
         """
    test "refuses an absolute alias nested inside the script's own module" do
      code = """
      defmodule Script.Escaper do
        defmodule Elixir.Enum do
        end
      end
      """

      assert {:error, {:module_outside_script, detail}} = Compiler.parse(code)
      assert detail =~ "Elixir."
    end

    test "allows a relative nested module, which stays under the tree" do
      code = """
      defmodule Script.Nested do
        defmodule Client do
          def call, do: :ok
        end
      end
      """

      assert {:ok, %{name: "nested"}} = Compiler.parse(code)
    end

    test "refuses two top-level modules" do
      code = "defmodule Script.One do\nend\n\ndefmodule Script.Two do\nend\n"

      assert {:error, {:several_top_modules, detail}} = Compiler.parse(code)
      assert detail =~ "Script.One"
      assert detail =~ "Script.Two"
    end

    test "refuses a computed module name" do
      for code <- [
            "defmodule unquote(name) do\nend\n",
            "defmodule @mod do\nend\n",
            "defmodule Module.concat(Script, Hex) do\nend\n"
          ] do
        assert {:error, {:dynamic_module_name, _detail}} = Compiler.parse(code)
      end
    end

    test "refuses code defining no module at all" do
      assert {:error, {:no_module, _detail}} = Compiler.parse("1 + 1\n")
      assert {:error, {:no_module, _detail}} = Compiler.parse("")
    end

    test "refuses a syntax error with the line it is on" do
      assert {:error, {:syntax_error, detail}} =
               Compiler.parse("defmodule Script.Broken do\n  def a do\n    1 +\n  end\nend\n")

      assert detail =~ "line"
    end
  end

  describe "compile/1" do
    test "answers the contract, the metadata and every module the code defined" do
      fixture = fixture()

      assert {:ok, compiled} = compile_fixture(fixture)
      assert compiled.name == fixture.name
      assert compiled.module == fixture.module
      assert compiled.modules == [fixture.module]
      assert compiled.contract == YmerNode.Script.contract()
      assert compiled.description == "a fixture script"

      assert compiled.declarations == %{
               hosts: [],
               url_action: nil,
               secrets: [],
               throttles: %{},
               cache: :text,
               web_fallback: false,
               libraries: %{}
             }

      assert compiled.warnings == []
    end

    @tag doc: """
         Guards the purge-before-compile order. Without it a second compile of
         the same tree emits two `redefining module` warnings, and those would
         be stored on the row and shown by `describe` as if the script's author
         had written something questionable. A failure means `warnings` is no
         longer empty on a clean recompile.
         """
    test "recompiling the same script warns about nothing" do
      fixture = fixture()

      assert {:ok, _first} = compile_fixture(fixture)
      assert {:ok, second} = Compiler.compile(fixture.code)
      assert second.warnings == []
    end

    test "carries a compile warning through without failing" do
      body = """
        @impl true
        def description, do: "warns"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def actions, do: %{noop: %{description: "n", properties: %{}, write: false}}

        @impl true
        def declarations, do: %{hosts: [], url_action: nil, secrets: []}

        @impl true
        def run(:noop, unused, _context), do: {:ok, %{}}
      """

      assert {:ok, compiled} = compile_fixture(fixture(body: body))
      assert [warning] = compiled.warnings
      assert warning =~ "script:"
      assert warning =~ "unused"
    end

    @tag doc: """
         The compile file name is what makes a run's stack frames readable: a
         raise inside a script renders as `script:<name>:<line>` rather than
         naming a file nobody can open. A failure means the file name stopped
         reaching the code server, and every future run's error will point at
         the wrong place.
         """
    test "compiles under a file name naming the script" do
      fixture = fixture()
      assert {:ok, _} = compile_fixture(fixture)

      assert_raise UndefinedFunctionError, fn -> fixture.module.nope() end

      frames =
        try do
          fixture.module.run(:boom, %{}, nil)
        rescue
          _ -> __STACKTRACE__
        end

      assert Enum.any?(frames, fn {_m, _f, _a, info} ->
               to_string(info[:file] || "") == "script:" <> fixture.name
             end)
    end

    test "refuses code that does not use the contract" do
      body = "  def description, do: \"nope\"\n"

      assert {:error, {:missing_contract, detail}} =
               compile_fixture(fixture(body: body, use: false))

      assert detail =~ "use YmerNode.Script"
    end

    @tag doc: """
         A behaviour's missing callback is a WARNING, measured on this
         toolchain: the module compiles, loads, and dies at the first call. This
         case is what turns that into a refusal at the write. A failure means
         the export check was dropped and a script can be stored that cannot
         run.
         """
    test "refuses a module that uses the contract but omits a callback" do
      body = "  @impl true\n  def description, do: \"incomplete\"\n"

      assert {:error, {:missing_callbacks, detail}} = compile_fixture(fixture(body: body))
      assert detail =~ "actions/0"
      assert detail =~ "run/3"
    end

    test "a refusal after the tree loaded unloads it, so a refused tree is never callable" do
      body = "  @impl true\n  def description, do: \"incomplete\"\n"
      %{module: module} = refused = fixture(body: body)

      assert {:error, {:missing_callbacks, _detail}} = compile_fixture(refused)
      refute :code.is_loaded(module)
    end
  end

  describe "compile/1 — the contract's values" do
    defp with_declarations(declarations, extra_actions \\ "") do
      """
        @impl true
        def description, do: "a fixture script"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def actions do
          %{noop: %{description: "does nothing", properties: %{}, write: false}#{extra_actions}}
        end

        @impl true
        def declarations, do: #{declarations}

        @impl true
        def run(_action, _args, _context), do: {:ok, %{}}
      """
    end

    test "refuses an empty description" do
      body =
        String.replace(
          with_declarations("%{hosts: [], url_action: nil, secrets: []}"),
          ~s|"a fixture script"|,
          ~s|"  "|
        )

      assert {:error, {:invalid_description, _detail}} = compile_fixture(fixture(body: body))
    end

    test "refuses an action schema missing its write mark" do
      body = """
        @impl true
        def description, do: "unmarked"

        @impl true
        def version, do: "1.0.0"

        @impl true
        def actions, do: %{noop: %{description: "n", properties: %{}}}

        @impl true
        def declarations, do: %{hosts: [], url_action: nil, secrets: []}

        @impl true
        def run(_action, _args, _context), do: {:ok, %{}}
      """

      assert {:error, {:invalid_actions, detail}} = compile_fixture(fixture(body: body))
      assert detail =~ ":write"
    end

    test "refuses a declarations map of the wrong shape" do
      assert {:error, {:invalid_declarations, _detail}} =
               compile_fixture(fixture(body: with_declarations("%{hosts: [\"a\"]}")))
    end

    test "refuses a host claim with no url_action to run" do
      body = with_declarations("%{hosts: [\"example.test\"], url_action: nil, secrets: []}")

      assert {:error, {:invalid_declarations, detail}} = compile_fixture(fixture(body: body))
      assert detail =~ ":url_action is nil"
    end

    test "refuses a url_action the action map does not declare" do
      body = with_declarations("%{hosts: [\"example.test\"], url_action: :absent, secrets: []}")

      assert {:error, {:invalid_declarations, detail}} = compile_fixture(fixture(body: body))
      assert detail =~ "actions/0 does not declare"
    end

    test "refuses a url_action whose schema has no url property" do
      body = with_declarations("%{hosts: [\"example.test\"], url_action: :noop, secrets: []}")

      assert {:error, {:invalid_declarations, detail}} = compile_fixture(fixture(body: body))
      assert detail =~ "no `url` property"
    end

    test "accepts a url_action that takes a url, and downcases the claimed hosts" do
      extra = ", fetch: %{description: \"f\", properties: %{\"url\" => %{}}, write: false}"

      body =
        with_declarations("%{hosts: [\"Example.TEST\"], url_action: :fetch, secrets: []}", extra)

      assert {:ok, compiled} = compile_fixture(fixture(body: body))

      assert compiled.declarations == %{
               hosts: ["example.test"],
               url_action: :fetch,
               secrets: [],
               throttles: %{},
               cache: :text,
               web_fallback: false,
               libraries: %{}
             }
    end

    test "keeps a declaration's throttles, and answers none for a script that declares none" do
      declarations = """
      %{
        hosts: [],
        url_action: nil,
        secrets: [],
        throttles: %{
          "acct" => %{rate: 60, burst: 2, breaker: %{threshold: 2, cooldown: 60_000}},
          "budget" => %{rate: 180, burst: 10}
        }
      }
      """

      assert {:ok, compiled} = compile_fixture(fixture(body: with_declarations(declarations)))

      assert compiled.declarations.throttles == %{
               "acct" => %{rate: 60, burst: 2, breaker: %{threshold: 2, cooldown: 60_000}},
               "budget" => %{rate: 180, burst: 10}
             }

      assert {:ok, plain} = compile_fixture(fixture())
      assert plain.declarations.throttles == %{}
    end

    test "reads the cache mode and the web fallback mark, text and neither when left out" do
      assert {:ok, plain} = compile_fixture(fixture())
      assert plain.declarations.cache == :text
      assert plain.declarations.web_fallback == false

      extra = ", fetch: %{description: \"f\", properties: %{\"url\" => %{}}, write: false}"

      declarations =
        "%{hosts: [], url_action: :fetch, secrets: [], cache: :file, web_fallback: true}"

      assert {:ok, compiled} =
               compile_fixture(fixture(body: with_declarations(declarations, extra)))

      assert compiled.declarations.cache == :file
      assert compiled.declarations.web_fallback == true
    end

    test "refuses a cache mode other than :text or :file" do
      body = with_declarations("%{hosts: [], url_action: nil, secrets: [], cache: :blob}")

      assert {:error, {:invalid_declarations, detail}} = compile_fixture(fixture(body: body))
      assert detail =~ ":cache must be :text or :file, got :blob"
    end

    test "refuses a web fallback mark that is not a boolean" do
      body = with_declarations("%{hosts: [], url_action: nil, secrets: [], web_fallback: :yes}")

      assert {:error, {:invalid_declarations, detail}} = compile_fixture(fixture(body: body))
      assert detail =~ ":web_fallback must be true or false, got :yes"
    end

    test "refuses a web fallback with no url_action to run" do
      body = with_declarations("%{hosts: [], url_action: nil, secrets: [], web_fallback: true}")

      assert {:error, {:invalid_declarations, detail}} = compile_fixture(fixture(body: body))
      assert detail =~ ":web_fallback needs a :url_action"
    end

    test "refuses throttles that break the grammar, naming the broken rule" do
      cases = [
        {"[]", ":throttles must be a map"},
        {~s|MapSet.new(["x"])|, ":throttles must be a map"},
        {~s|%{"A 1" => %{rate: 60, burst: 2}}|, ~s|throttle name "A 1"|},
        {"%{a: %{rate: 60, burst: 2}}", "throttle name :a"},
        {~s|%{"a" => [rate: 60]}|, "a: its parameters must be a map"},
        {~s|%{"a" => %{burst: 2}}|, "a: :rate is required"},
        {~s|%{"a" => %{rate: 0, burst: 2}}|, "a: :rate must be a positive integer"},
        {~s|%{"a" => %{rate: 60, burst: 2, ceiling: 5}}|, "a: :ceiling is not a key"},
        {~s|%{"a" => %{rate: 60, burst: 2, breaker: 2}}|, "a: :breaker must be a map"},
        {~s|%{"a" => %{rate: 1, burst: 1, breaker: %{cooldown: 5}}}|, "a: :threshold is required"}
      ]

      for {throttles, fault} <- cases do
        declarations = "%{hosts: [], url_action: nil, secrets: [], throttles: #{throttles}}"

        assert {:error, {:invalid_declarations, detail}} =
                 compile_fixture(fixture(body: with_declarations(declarations))),
               "#{throttles} was not refused"

        assert detail =~ fault
      end
    end

    test "keeps the libraries a script declares, and answers none for a script that declares none" do
      declarations =
        ~s|%{hosts: [], url_action: nil, secrets: [], libraries: %{"crosskey" => "~> 1.0"}}|

      assert {:ok, compiled} = compile_fixture(fixture(body: with_declarations(declarations)))
      assert compiled.declarations.libraries == %{"crosskey" => "~> 1.0"}

      assert {:ok, plain} = compile_fixture(fixture())
      assert plain.declarations.libraries == %{}
    end

    test "refuses libraries that break the grammar, naming the broken rule" do
      cases = [
        {"[]", ":libraries must be a map"},
        {~s|%{"Crosskey" => "~> 1.0"}|, ~s|library name "Crosskey"|},
        {~s|%{crosskey: "~> 1.0"}|, "library name :crosskey"},
        {~s|%{"crosskey" => nil}|, "library crosskey: nil is not a requirement"},
        {~s|%{"crosskey" => "1.0"}|, ~s|library crosskey: "1.0" is not a requirement|}
      ]

      for {libraries, fault} <- cases do
        declarations = "%{hosts: [], url_action: nil, secrets: [], libraries: #{libraries}}"

        assert {:error, {:invalid_declarations, detail}} =
                 compile_fixture(fixture(body: with_declarations(declarations))),
               "#{libraries} was not refused"

        assert detail =~ fault
      end
    end

    @tag doc: """
         Guards against a declarations key being dropped instead of refused. A node
         that dropped a key it does not read would run a script written for a newer
         node without what that key asked for, so a failure here means an unknown
         key is being dropped again.
         """
    test "refuses a key it does not read, naming it and the keys it does" do
      body = with_declarations("%{hosts: [], url_action: nil, secrets: [], repos: []}")

      assert {:error, {:invalid_declarations, detail}} = compile_fixture(fixture(body: body))
      assert detail =~ ":repos is not a declaration this node reads"
      assert detail =~ ":libraries"
    end
  end

  describe "compile/1 — the version" do
    test "answers the version a script reports" do
      assert {:ok, compiled} = compile_fixture(fixture())
      assert compiled.version == "1.0.0"
      assert compiled.kind == :script
      assert compiled.api == nil
    end

    test "refuses a version Version does not read" do
      body = String.replace(fixture().code |> body_of(), ~s|"1.0.0"|, ~s|"1.0"|)

      assert {:error, {:invalid_version, detail}} = compile_fixture(fixture(body: body))
      assert detail =~ ~s|version/0 answers "1.0"|
    end

    @tag doc: """
         A row written before the version callback existed fails exactly this way
         at boot, and the detail is all an operator reading the boot log or
         `describe` gets, so it has to carry the fix as well as the callback.
         """
    test "refuses a script without version/0, naming it and the fix" do
      body =
        String.replace(
          body_of(fixture().code),
          ~s|  @impl true\n  def version, do: "1.0.0"\n|,
          ""
        )

      assert {:error, {:missing_callbacks, detail}} = compile_fixture(fixture(body: body))

      assert detail =~
               "version/0 — add it, then store the code with `create` if it is new, or again with `update`"
    end
  end

  describe "parse/1 and compile/1 — a library" do
    test "derives a library's name and kind from Library.<Name>" do
      assert {:ok, %{name: "crosskey", module: Library.Crosskey, kind: :library}} =
               Compiler.parse("defmodule Library.Crosskey do\nend\n")
    end

    test "answers a library's version, contract and documented API, and no actions" do
      library = library_fixture()

      assert {:ok, compiled} = compile_fixture(library)
      assert compiled.kind == :library
      assert compiled.name == library.name
      assert compiled.contract == YmerNode.Library.contract()
      assert compiled.version == "1.0.0"
      assert compiled.description == "a fixture library"
      assert compiled.actions == %{}
      assert compiled.declarations == nil

      assert compiled.api == [
               %{
                 name: "#{inspect(library.module)}.echo/1",
                 signature: "echo(value)",
                 doc: "Answers what it is handed."
               }
             ]
    end

    test "refuses a library naming another library, at the parse" do
      body = """
        def call, do: Library.Jira.get()
      """

      assert {:error, {:undeclared_library, detail}} =
               Compiler.parse(library_fixture(body: body).code)

      assert detail =~ "Library.Jira is another library"
    end

    test "refuses each contract under the other kind's namespace" do
      script_body = "  use YmerNode.Script\n\n" <> body_of(fixture().code)
      library = library_fixture(use: false, body: script_body)

      assert {:error, {:contract_mismatch, detail}} = compile_fixture(library)
      assert detail =~ "uses YmerNode.Script under `Library.`"

      library_body = "  use YmerNode.Library\n\n" <> body_of(library_fixture().code)
      script = fixture(use: false, body: library_body)

      assert {:error, {:contract_mismatch, detail}} = compile_fixture(script)
      assert detail =~ "uses YmerNode.Library under `Script.`"
    end
  end

  describe "parse/1 and compile/1 — the libraries a script names" do
    test "collects every Library. alias, the braces form included" do
      code = """
      defmodule Script.Names do
        alias Library.{Crosskey, Jira}
        require Library.Typesetting

        def go, do: {Crosskey, Jira, Library.HTTPClient.get()}
      end
      """

      assert {:ok, %{kind: :script, libraries: libraries}} = Compiler.parse(code)

      assert libraries == %{
               "crosskey" => "Library.Crosskey",
               "jira" => "Library.Jira",
               "typesetting" => "Library.Typesetting",
               "http_client" => "Library.HTTPClient"
             }
    end

    test "reads Elixir.Library.<Name> as the library it names, in a script and a library" do
      code = """
      defmodule Script.Names do
        def go, do: Elixir.Library.Jira.get()
      end
      """

      assert {:ok, %{libraries: %{"jira" => "Library.Jira"}}} = Compiler.parse(code)

      body = """
        def call, do: Elixir.Library.Jira.get()
      """

      assert {:error, {:undeclared_library, detail}} =
               Compiler.parse(library_fixture(body: body).code)

      assert detail =~ "Library.Jira is another library"
    end

    test "refuses Library written alone, in a script and a library" do
      code = """
      defmodule Script.Names do
        alias Library, as: L

        def go, do: L.Jira.get()
      end
      """

      assert {:error, {:undeclared_library, detail}} = Compiler.parse(code)
      assert detail =~ "alias each library in full"

      body = """
        alias Library, as: L

        def call, do: L.Jira.get()
      """

      assert {:error, {:undeclared_library, _detail}} =
               Compiler.parse(library_fixture(body: body).code)
    end

    test "fails the compile on a require of a library the node does not hold, declared or not" do
      undeclared = with_declarations("%{hosts: [], url_action: nil, secrets: []}")

      declared =
        with_declarations(
          ~s|%{hosts: [], url_action: nil, secrets: [], libraries: %{"gone" => "~> 1.0"}}|
        )

      for body <- [undeclared, declared] do
        assert {:error, {:compile_error, _detail}} =
                 compile_fixture(fixture(body: "  require Library.Gone\n\n" <> body))
      end
    end

    test "refuses a script calling a library its declarations do not name" do
      library = library_fixture()
      assert {:ok, _library} = compile_fixture(library)

      body =
        with_declarations("%{hosts: [], url_action: nil, secrets: []}")
        |> String.replace(
          "def run(_action, _args, _context), do: {:ok, %{}}",
          "def run(_action, _args, _context), do: {:ok, #{inspect(library.module)}.echo(%{})}"
        )

      assert {:error, {:undeclared_library, detail}} = compile_fixture(fixture(body: body))
      assert detail =~ "the code names #{inspect(library.module)}"
      assert detail =~ ~s|add "#{library.name}" to :libraries|

      declared =
        String.replace(
          body,
          "secrets: []}",
          ~s|secrets: [], libraries: %{"#{library.name}" => "~> 1.0"}}|
        )

      assert {:ok, compiled} = compile_fixture(fixture(body: declared))
      assert compiled.declarations.libraries == %{library.name => "~> 1.0"}
      assert compiled.warnings == []
    end
  end

  # The callbacks between a fixture's `defmodule` line and its final `end`.
  defp body_of(code) do
    code |> String.split("\n", parts: 2) |> List.last() |> String.replace_suffix("end\n", "")
  end
end
