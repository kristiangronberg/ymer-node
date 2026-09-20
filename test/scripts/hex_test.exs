defmodule Script.HexTest do
  @moduledoc """
  The example script, run against a stub rather than against hex.pm.

  `config/test.exs` points every script request at `Req.Test` under the
  `YmerNode.Script.Context` name, so this file stubs there and nothing in the
  suite reaches the network — the standing absence the repo has always had. A
  case that forgets to stub does not fall through to hex.pm: it meets Req.Test's
  own "no stub" failure, which is the arrangement's whole point.

  The script is compiled from its file on disk, through the same compiler an
  MCP `create` uses. That is deliberate: `priv/scripts/hex.exs` is what the
  build plants on a fresh install, and what an operator can push by hand, so
  what these cases must prove is that **the shipped bytes** satisfy the
  contract, not that some fixture resembling them does.

  There is no case here that hits hex.pm for real. The live smoke is documented
  in the plan and run by hand; a gate that needed the network would fail on a
  train.
  """
  use YmerNode.ScriptCase, async: true

  alias YmerNode.Script.Context
  alias YmerNode.Scripts.Compiler

  @path "priv/scripts/hex.exs"

  @body %{
    "name" => "req",
    "html_url" => "https://hex.pm/packages/req",
    "latest_stable_version" => "0.7.4",
    "downloads" => %{"all" => 42_000_000},
    "meta" => %{
      "description" => "Req is a batteries-included HTTP client for Elixir.",
      "licenses" => ["Apache-2.0"],
      "links" => %{"GitHub" => "https://github.com/wojtekmach/req"}
    },
    "releases" => [%{"version" => "0.7.4"}, %{"version" => "0.7.3"}]
  }

  setup do
    # `Module.concat/1`'s string form, and `module` from the compile rather than
    # the literal `Script.Hex`: the module does not exist until this setup runs,
    # so naming it in this file's code would warn that it is undefined — and `mix
    # precommit` compiles the suite with `--warnings-as-errors`.
    purge_on_exit(Module.concat(["Script", "Hex"]))
    {:ok, compiled} = @path |> File.read!() |> Compiler.compile()

    %{compiled: compiled, module: compiled.module}
  end

  # The batteries a run receives, built here rather than carried in the ExUnit
  # context: a test head naming two keys reflows across four lines, and what
  # every case actually varies is the module, not this.
  defp context(action \\ :package) do
    %Context{
      script: "hex",
      action: action,
      secrets: [],
      throttles: %{},
      deadline: System.monotonic_time(:millisecond) + 30_000
    }
  end

  describe "the shipped file satisfies the contract" do
    @tag doc: """
         The file on disk is what an operator pushes, so the contract has to
         hold for those bytes. A failure means `priv/scripts/hex.exs` and the
         node's contract drifted apart — and the operator would find out at the
         push, with no test having said so first.
         """
    test "compiles under the node's own compiler, deriving the name hex", %{compiled: compiled} do
      assert compiled.name == "hex"
      assert compiled.module == Module.concat(["Script", "Hex"])
      assert compiled.contract == 1
      assert compiled.warnings == []
    end

    test "declares hex.pm through an action that takes a url", %{compiled: compiled} do
      assert compiled.declarations == %{
               hosts: ["hex.pm"],
               url_action: :fetch,
               secrets: [],
               throttles: %{}
             }

      assert Map.has_key?(compiled.actions.fetch.properties, "url")
    end

    @tag doc: """
         Both actions read. A `write: true` creeping in here would be a change
         of kind, not of degree: the example is what an author copies, and it
         teaches the write mark by carrying the right one.
         """
    test "serves two read actions and declares no secret", %{compiled: compiled} do
      assert Map.keys(compiled.actions) |> Enum.sort() == [:fetch, :package]
      refute compiled.actions.package.write
      refute compiled.actions.fetch.write
      assert compiled.declarations.secrets == []
    end
  end

  describe "package" do
    test "asks hex.pm for the named package and summarises the answer", %{module: module} do
      Req.Test.stub(Context, fn conn ->
        assert conn.request_path == "/api/packages/req"
        Req.Test.json(conn, @body)
      end)

      assert {:ok, summary} = module.run(:package, %{"name" => "req"}, context())
      assert summary["name"] == "req"
      assert summary["latest_version"] == "0.7.4"
      assert summary["links"] == %{"GitHub" => "https://github.com/wojtekmach/req"}
    end

    @tag doc: """
         The summary is the point of the action, not an accident of it: hex.pm's
         payload carries every release ever made, and the answer goes into a
         worker's context window. A failure means the whole body started coming
         back — thousands of bytes where seven fields were asked for.
         """
    test "leaves the release list out of the answer", %{module: module} do
      Req.Test.stub(Context, fn conn -> Req.Test.json(conn, @body) end)

      assert {:ok, summary} = module.run(:package, %{"name" => "req"}, context())
      refute Map.has_key?(summary, "releases")
      assert Map.keys(summary) |> length() == 7
    end

    test "escapes a name rather than pasting it into the path", %{module: module} do
      Req.Test.stub(Context, fn conn ->
        assert conn.request_path == "/api/packages/a%2Fb"
        Req.Test.json(conn, @body)
      end)

      assert {:ok, _summary} = module.run(:package, %{"name" => "a/b"}, context())
    end

    test "answers a plain error for an unknown package", %{module: module} do
      Req.Test.stub(Context, fn conn -> Plug.Conn.send_resp(conn, 404, "") end)

      assert {:error, "no such package on hex.pm"} =
               module.run(:package, %{"name" => "nope"}, context())
    end

    test "names the status for anything else hex.pm answers", %{module: module} do
      Req.Test.stub(Context, fn conn -> Plug.Conn.send_resp(conn, 503, "") end)

      assert {:error, "hex.pm answered 503"} =
               module.run(:package, %{"name" => "req"}, context())
    end

    test "answers the transport failure's own message", %{module: module} do
      Req.Test.stub(Context, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, message} = module.run(:package, %{"name" => "req"}, context())
      assert message =~ "connection refused"
    end
  end

  describe "fetch — the url action" do
    test "reads the package name out of a package page url", %{module: module} do
      Req.Test.stub(Context, fn conn ->
        assert conn.request_path == "/api/packages/req"
        Req.Test.json(conn, @body)
      end)

      assert {:ok, %{"name" => "req"}} =
               module.run(:fetch, %{"url" => "https://hex.pm/packages/req"}, context())
    end

    test "reads it out of an API url too", %{module: module} do
      Req.Test.stub(Context, fn conn -> Req.Test.json(conn, @body) end)

      assert {:ok, %{"name" => "req"}} =
               module.run(:fetch, %{"url" => "https://hex.pm/api/packages/req"}, context(:fetch))
    end

    @tag doc: """
         A hex.pm url that names no package is REFUSED rather than guessed at.
         The host is claimed, so every reference on it routes here — and a guess
         would answer some other package's metadata as though it were the one
         asked for, which is worse than an error a caller can read.
         """
    test "refuses a hex.pm url that names no package", %{module: module} do
      for url <- ["https://hex.pm/", "https://hex.pm/docs/usage", "https://hex.pm/packages/"] do
        assert {:error, message} = module.run(:fetch, %{"url" => url}, context())
        assert message =~ "not a hex.pm package url"
      end
    end

    @tag doc: """
         The host is checked, not only the path. The seam hands this action out
         for hex.pm uris, but `scripts run` takes any url, and `/packages/req`
         on some other host is not hex.pm's `req` — answering hex.pm's metadata
         for it is the confidently wrong answer the path rule already refuses.
         """
    test "refuses another host's package-shaped url, and reads hex.pm in any case", %{
      module: module
    } do
      Req.Test.stub(Context, fn conn -> Req.Test.json(conn, @body) end)

      assert {:error, message} =
               module.run(:fetch, %{"url" => "https://evil.example/packages/req"}, context())

      assert message =~ "not a hex.pm package url"

      assert {:ok, %{"name" => "req"}} =
               module.run(:fetch, %{"url" => "https://HEX.PM/packages/req"}, context(:fetch))
    end
  end
end
