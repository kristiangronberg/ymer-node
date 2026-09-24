defmodule YmerNode.ScriptContextTest do
  @moduledoc """
  No database and no network. Outbound requests are stubbed through `Req.Test`
  under the `YmerNode.Script.Context` name, which is the stub `config/test.exs`
  wires into the module's own `request_options/0` — a case that forgets to stub
  gets Req.Test's "no stub" failure rather than a real call.

  **Not async**, and neither the database nor the network is the reason: the
  secret cases point `YmerNode.Secrets` at a file of their own by setting
  `config :ymer_node, YmerNode.Secrets, :path`, which is VM-global application
  config that `YmerNode.SecretsTest`, `YmerNode.ScriptHarnessTest` and
  `YmerNode.ScriptTestSupportTest` set too. `YmerNode.SecretsTest`'s
  `@moduledoc` carries the measurement of what the race looks like when two of
  them run async.

  The zone cases set VM-global config too — `time_zone` under
  `YmerNode.Script.Context`: the configured case merges it into the keyword
  list `config/test.exs` keeps there, and the default case removes that key
  whole for its duration, the state a node booted without `TZ` is in. Both
  put the list back on exit, because the `Req.Test` plug every request case
  relies on lives in it. The files directory cases take the same shape over
  `files_dir`, and the absent-key case deletes that one key rather than the
  list, for the same reason.

  The four notebook forwards (`execute/2`, `query/2`, `tables/1`,
  `table_schema/2`) are not exercised here: each is a single expression naming a
  public `YmerNode.Notebook` function, so a wrong name is an undefined-function
  warning and `mix precommit` compiles with `--warnings-as-errors`. What they
  forward *to* is `YmerNode.NotebookTest`'s subject, and duplicating it here
  would need the notebook's sandbox and cost this module its async.

  The three render forwards are exercised, for the opposite reason: what the
  cases prove is the node's own policy underneath a script's options — the
  files directory as the document's root, and a script's own value winning —
  which lives here and not in the package. They render for real, and their
  `setup` points `files_dir` at a directory of the case's own under the same
  VM-global key the cases above use.
  """
  use ExUnit.Case, async: false

  alias YmerNode.Script.Context
  alias YmerNode.Scripts.Throttle
  alias YmerNode.Scripts.Throttle.Error
  alias YmerNode.Secrets

  defmodule UsesContract do
    @moduledoc false
    use YmerNode.Script

    @impl true
    def description, do: "a fixture"

    @impl true
    def actions, do: %{noop: %{description: "does nothing", properties: %{}, write: false}}

    @impl true
    def declarations, do: %{hosts: [], url_action: nil, secrets: []}

    @impl true
    def run(:noop, _args, _context), do: {:ok, %{}}
  end

  defp context(secrets \\ [], throttles \\ %{}) do
    %Context{
      script: "fixture",
      action: :noop,
      secrets: secrets,
      throttles: throttles,
      deadline: System.monotonic_time(:millisecond) + 5_000
    }
  end

  describe "use YmerNode.Script" do
    test "stamps the behaviour and the contract version" do
      assert YmerNode.Script in UsesContract.__info__(:attributes)[:behaviour]
      assert UsesContract.__script_contract__() == YmerNode.Script.contract()
    end

    @tag doc: """
         The contract version is what a row records, and a node that will not
         speak a row's version refuses it by name. A failure here means the
         stamp stopped being readable off a compiled module — which is exactly
         the failure a plain module attribute would have had, and the reason
         `__using__/1` generates a function instead.
         """
    test "the version is a positive integer readable off the compiled module" do
      assert is_integer(YmerNode.Script.contract())
      assert YmerNode.Script.contract() > 0
    end

    test "the required callbacks are the four the compiler cannot enforce" do
      assert YmerNode.Script.callbacks() == [
               {:description, 0},
               {:actions, 0},
               {:declarations, 0},
               {:run, 3}
             ]

      for {name, arity} <- YmerNode.Script.callbacks() do
        assert function_exported?(UsesContract, name, arity)
      end
    end
  end

  describe "secret/2" do
    setup %{} do
      saved = Application.get_env(:ymer_node, Secrets)
      path = Path.join(System.tmp_dir!(), "ctx-secrets-#{System.unique_integer([:positive])}.env")
      Application.put_env(:ymer_node, Secrets, path: path)

      on_exit(fn ->
        File.rm(path)
        if saved, do: Application.put_env(:ymer_node, Secrets, saved)
      end)

      File.write!(path, "DECLARED=value\nSNEAKY=other\n")
      File.chmod!(path, 0o600)
      %{path: path}
    end

    test "resolves a declared name" do
      assert Context.secret(context(["DECLARED"]), "DECLARED") == {:ok, "value"}
    end

    @tag doc: """
         Guards the whole point of declaring secrets: the list is enforced, not
         documentation. A failure means a script could read any secret on the
         machine while its declarations named none — and the human who accepted
         its code would have had no way to see that from what `describe` showed
         them.
         """
    test "refuses an undeclared name even when the file sets it" do
      assert Context.secret(context(["DECLARED"]), "SNEAKY") ==
               {:error, {:secret_undeclared, "SNEAKY"}}
    end

    @tag doc: """
         The name has to survive the refusal. A run that hands this error back
         is answered by naming the secret and the verb that sets it, and the
         name it uses is this one — a bare `:secret_not_found` would leave a
         caller with several declared secrets reading the script's code to work
         out which of them it wanted.
         """
    test "declared but unset names the secret, with or without a file", %{path: path} do
      assert Context.secret(context(["ABSENT"]), "ABSENT") ==
               {:error, {:secret_not_found, "ABSENT"}}

      File.rm!(path)

      assert Context.secret(context(["ABSENT"]), "ABSENT") ==
               {:error, {:secret_not_found, "ABSENT"}}
    end
  end

  describe "time_zone/1" do
    setup do
      saved = Application.get_env(:ymer_node, Context)

      on_exit(fn ->
        if saved,
          do: Application.put_env(:ymer_node, Context, saved),
          else: Application.delete_env(:ymer_node, Context)
      end)

      %{config: saved || []}
    end

    test "answers the zone the node is configured with", %{config: config} do
      Application.put_env(
        :ymer_node,
        Context,
        Keyword.put(config, :time_zone, "Europe/Helsinki")
      )

      assert Context.time_zone(context()) == "Europe/Helsinki"
    end

    test "answers Etc/UTC when no zone is configured" do
      Application.delete_env(:ymer_node, Context)

      assert Context.time_zone(context()) == "Etc/UTC"
    end
  end

  describe "files_dir/1" do
    setup do
      saved = Application.get_env(:ymer_node, Context)

      on_exit(fn ->
        if saved,
          do: Application.put_env(:ymer_node, Context, saved),
          else: Application.delete_env(:ymer_node, Context)
      end)

      %{config: saved || []}
    end

    test "answers the directory the node is configured with, as a string", %{config: config} do
      Application.put_env(:ymer_node, Context, Keyword.put(config, :files_dir, "/data/files"))

      assert Context.files_dir(context()) == "/data/files"
    end

    test "names the harness setter a VM outside the node points the key with", %{config: config} do
      Application.put_env(:ymer_node, Context, Keyword.delete(config, :files_dir))

      error = assert_raise ArgumentError, fn -> Context.files_dir(context()) end

      assert error.message =~ "YmerNode.Script.Harness.put_files_dir/1"
    end

    @tag doc: """
         The node's own environments set the key — `config/runtime.exs` from
         `FILES_PATH`, `config/dev.exs` and `config/test.exs` with a directory of
         their own — and a VM running scripts outside the node points it with
         `YmerNode.Script.Harness.put_files_dir/1`. So an absent key is a
         configuration defect, and the reader refuses it by name rather than
         inventing a default a script would then write into. A failure means a
         default came back, and a misconfigured node would quietly read and write
         files somewhere nobody arranged.
         """
    test "refuses an absent key naming it, never a default", %{config: config} do
      Application.put_env(:ymer_node, Context, Keyword.delete(config, :files_dir))

      error = assert_raise ArgumentError, fn -> Context.files_dir(context()) end

      assert error.message =~ "files_dir"
      assert error.message =~ "FILES_PATH"
    end
  end

  describe "request/2" do
    test "merges the node's options under the script's and answers Req's own shape" do
      Req.Test.stub(Context, fn conn ->
        assert conn.request_path == "/packages/wymcp"
        Req.Test.json(conn, %{"name" => "wymcp"})
      end)

      assert {:ok, %Req.Response{status: 200, body: %{"name" => "wymcp"}}} =
               Context.request(context(), url: "https://hex.test/packages/wymcp")
    end

    @tag doc: """
         Guards `retry: false`. Req retries a transport error three times by
         default, which spends most of a bounded run asleep — measured at six
         and a half seconds for a single refused connection. A failure means the
         default came back or the merge order inverted, and every failing run
         now costs the caller a multi-second wait before its error.
         """
    test "does not retry a transport error" do
      Req.Test.stub(Context, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      {elapsed, result} =
        :timer.tc(fn -> Context.request(context(), url: "https://hex.test/x") end)

      assert {:error, %Req.TransportError{reason: :econnrefused}} = result
      assert elapsed < 1_000_000
    end

    test "the script's own options win over the node's" do
      Req.Test.stub(Context, fn conn -> Req.Test.json(conn, %{"seen" => true}) end)

      assert {:ok, %Req.Response{body: %{"seen" => true}}} =
               Context.request(context(), url: "https://hex.test/x", receive_timeout: 500)
    end

    @tag doc: """
         Guards the request being built through `Req.new/1`, which pops
         `plugins:` and runs each plugin before the throttle's steps attach.
         Built through `Req.merge/2` instead, a script passing a plugin raises
         `ArgumentError` for an unregistered option inside the run.
         """
    test "runs a plugin the script passes, as Req does" do
      Req.Test.stub(Context, fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-plugin") == ["ran"]
        Req.Test.json(conn, %{})
      end)

      plugin = &Req.Request.put_header(&1, "x-plugin", "ran")

      assert {:ok, %Req.Response{status: 200}} =
               Context.request(context(), url: "https://hex.test/x", plugins: [plugin])
    end
  end

  describe "request/2 — throttles" do
    test "refuses a throttle its declarations do not name, before anything is sent" do
      Req.Test.stub(Context, fn _conn -> raise "the request was sent" end)

      assert {:error, %Error{reason: :undeclared, throttle: "absent", message: message}} =
               Context.request(context(), url: "https://hex.test/x", throttle: "absent")

      assert message =~ "which its declarations/0 does not name"
    end

    test "a request through a declared throttle spends one of its tokens" do
      name = "ctx-#{System.unique_integer([:positive])}"
      Req.Test.stub(Context, fn conn -> Req.Test.json(conn, %{}) end)
      context = context([], %{name => %{rate: 60, burst: 2}})

      assert {:ok, %Req.Response{status: 200}} =
               Context.request(context, url: "https://hex.test/x", throttle: name)

      assert %{tokens: tokens} = Enum.find(Throttle.list(), &(&1.name == name))
      assert tokens < 2
    end

    test "an open breaker refuses the next request with the verb that resets it" do
      name = "ctx-#{System.unique_integer([:positive])}"
      Req.Test.stub(Context, fn conn -> Plug.Conn.send_resp(conn, 401, "") end)
      throttle = %{rate: 600, burst: 5, breaker: %{threshold: 1, cooldown: 60_000}}
      context = context([], %{name => throttle})

      assert {:ok, %Req.Response{status: 401}} =
               Context.request(context, url: "https://hex.test/x", throttle: name)

      assert {:error, %Error{reason: :open, message: message}} =
               Context.request(context, url: "https://hex.test/x", throttle: name)

      assert message =~ "`ymer-node throttles reset #{name}`"
    end
  end

  describe "render_options/0" do
    setup :files_directory

    @tag doc: """
         The policy's fixed half, read where the merge reads it. `cache_fonts:
         false` is the promise the render policy makes — a font installed since
         the node started is seen by the next render — and no render case can
         see the value, because every font a test may source is already in the
         set the package always scans. A failure means the default flipped, and
         the guide's freshness sentence reads false on every node that keeps
         the default.
         """
    test "defaults to a fresh font scan on every render" do
      Application.put_env(
        :ymer_node,
        Context,
        Keyword.delete(Application.get_env(:ymer_node, Context, []), :render_options)
      )

      assert Context.render_options() == [cache_fonts: false]
    end

    @tag doc: """
         The configured half reaches the package through the same merge a
         script's own options do, and stays underneath them. The NIF refuses a
         non-boolean `cache_fonts`, so a value the node would never send is what
         shows the config arrived; the script's own `false` then winning over it
         is the order. A failure on the first means an operator's
         `cache_fonts: true` on a slow machine changes nothing; on the second,
         that a script can no longer override the node.
         """
    test "the configured options reach the package underneath a script's own" do
      Application.put_env(
        :ymer_node,
        Context,
        Keyword.put(
          Application.get_env(:ymer_node, Context, []),
          :render_options,
          cache_fonts: "not a boolean"
        )
      )

      assert_raise ArgumentError, fn -> Context.render_to_pdf(context(), "= x") end
      assert {:ok, _pdf} = Context.render_to_pdf(context(), "= x", [], cache_fonts: false)
    end
  end

  describe "render_to_pdf/4" do
    setup :files_directory

    test "renders a two-file document rooted at the files directory", %{files_dir: directory} do
      File.write!(Path.join(directory, "tpl.typ"), template())

      assert {:ok, pdf} = Context.render_to_pdf(context(), markup(), summary: "All green")
      assert String.starts_with?(pdf, "%PDF-")
    end

    @tag doc: """
         Pins the merge order of the node's *policy* (`docs/glossary.md`): the
         package names the root it searched in the error text, which is what
         lets this read the merged root back out of one failed render. A
         failure means the merge order inverted, and a script could no longer
         override the node — check the argument order of `Keyword.merge/2`
         behind the three renders before touching this test.
         """
    test "the script's own root_dir wins over the node's", %{files_dir: directory} do
      File.write!(Path.join(directory, "tpl.typ"), template())
      elsewhere = Path.join(directory, "elsewhere")

      assert {:error, message} =
               Context.render_to_pdf(context(), markup(), [summary: "x"], root_dir: elsewhere)

      assert message =~ "file not found (searched at #{Path.join(elsewhere, "tpl.typ")})"
    end

    @tag doc: """
         The other half of the merge, for the key the policy sets to `false`.
         The package hands `cache_fonts` to the NIF, which refuses anything
         that is not a boolean — so a value the node would never send is the
         one way to watch a script's own reach it. A failure means the key
         stopped being overridable, and a script looping many renders can no
         longer ask for the cache.
         """
    test "the script's own cache_fonts reaches the package" do
      assert_raise ArgumentError, fn ->
        Context.render_to_pdf(context(), "= x", [], cache_fonts: "not a boolean")
      end
    end

    test "refuses before the package is called when no files directory is configured" do
      Application.put_env(
        :ymer_node,
        Context,
        Keyword.delete(Application.get_env(:ymer_node, Context, []), :files_dir)
      )

      error = assert_raise ArgumentError, fn -> Context.render_to_pdf(context(), "= x") end

      assert error.message =~ "files_dir"
    end
  end

  describe "render_to_png/4" do
    setup :files_directory

    test "renders one PNG per page, rooted at the files directory", %{files_dir: directory} do
      File.write!(Path.join(directory, "tpl.typ"), template())

      assert {:ok, pages} = Context.render_to_png(context(), markup(), summary: "All green")
      assert length(pages) == 2
      assert Enum.all?(pages, &is_binary/1)
    end
  end

  describe "render_to_svg/4" do
    setup :files_directory

    test "renders one SVG per page, rooted at the files directory", %{files_dir: directory} do
      File.write!(Path.join(directory, "tpl.typ"), template())

      assert {:ok, [first, _second]} = Context.render_to_svg(context(), markup(), summary: "ok")
      assert String.starts_with?(first, "<svg")
    end
  end

  defp files_directory(_context) do
    saved = Application.get_env(:ymer_node, Context)
    directory = Path.join(System.tmp_dir!(), "ctx-render-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    Application.put_env(:ymer_node, Context, Keyword.put(saved || [], :files_dir, directory))

    on_exit(fn ->
      File.rm_rf!(directory)

      if saved,
        do: Application.put_env(:ymer_node, Context, saved),
        else: Application.delete_env(:ymer_node, Context)
    end)

    %{files_dir: directory}
  end

  defp template, do: "#let banner(body) = align(center, text(size: 18pt, body))\n"

  defp markup do
    Enum.join(
      [
        ~s(#import "tpl.typ": banner),
        "#banner[Weekly status]",
        "<%= summary %>",
        "#pagebreak()",
        "= Second page"
      ],
      "\n"
    )
  end
end
