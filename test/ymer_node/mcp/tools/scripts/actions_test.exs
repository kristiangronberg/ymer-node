defmodule YmerNode.Mcp.Tools.Scripts.ActionsTest do
  @moduledoc """
  The boundary's own cases: they go through `YmerNode.Scripts`, so the sandbox
  owns them and the module is not async. Fixtures compile into the VM, so each
  registers its own purge and every segment is unique.

  What this file is for, beyond the happy paths, is the **wrong-typed twins**.
  `YmerNode.Scripts.run/3` and `YmerNode.Scripts.Runner.run/3` both guard
  `is_binary(action)`, so without a twin a wire call carrying `action: 123`
  raises `FunctionClauseError` and the caller is told nothing it can act on.
  Every twin case asserts a `{:error, {{:wrong_type, _}, _}}` came back — a
  MESSAGE, not a crash — and `mix precommit` passing is not evidence for any of
  them, because a crash in a call nobody makes is invisible to it.
  """
  use YmerNode.DataCase

  alias YmerNode.Mcp.Tools.Scripts.Actions
  alias YmerNode.Scripts
  alias YmerNode.Scripts.Compiler
  alias YmerNode.Scripts.Script

  describe "list" do
    test "answers a count and one slim entry per script" do
      script = create!(segment())

      assert {:ok, %{count: 1, scripts: [entry]}, %{}} = Actions.run(:list, %{})
      assert entry.name == script.name
      assert entry.accepted == true
      assert entry.actions == ["fetch", "ping"]
      refute Map.has_key?(entry, :code)
    end

    test "answers an empty registry without complaint" do
      assert {:ok, %{count: 0, scripts: []}, %{}} = Actions.run(:list, %{})
    end
  end

  describe "describe" do
    test "answers the full shape and steers at a run" do
      script = create!(segment())

      assert {:ok, detail, hint_context} = Actions.run(:describe, %{"script" => script.name})
      assert detail.contract == 1
      assert %{"ping" => %{write: false}} = detail.actions
      refute Map.has_key?(detail, :code)
      assert hint_context == %{script: script.name, action: "fetch"}
    end

    test "carries the code when it is asked for" do
      script = create!(segment())

      assert {:ok, detail, _hint} =
               Actions.run(:describe, %{"script" => script.name, "code" => true})

      assert detail.code == script.code
    end

    test "steers at sharing as well when the code is asked for" do
      script = create!(segment())

      assert {:ok, _detail, hint_context} =
               Actions.run(:describe, %{"script" => script.name, "code" => true})

      assert hint_context == %{script: script.name, action: "fetch", code: true}
    end

    test "steers nowhere for a script that could not run" do
      script = create!(segment())

      script
      |> Script.changeset(%{accepted_hash: "not the code hash"})
      |> Repo.update!()

      assert {:ok, detail, hint_context} = Actions.run(:describe, %{"script" => script.name})
      assert detail.accepted == false
      assert hint_context == %{}
    end

    test "refuses a script that is not there" do
      assert {:error, {{:not_found, _detail}, %{action_verb: "describe a script"}}} =
               Actions.run(:describe, %{"script" => "absent"})
    end
  end

  describe "guide" do
    test "answers the contract's text as one guide, with nothing to steer at" do
      assert {:ok, %{guide: text}, %{}} = Actions.run(:guide, %{})
      assert text =~ "# YmerNode.Script\n"
      assert text =~ "# YmerNode.Script.Context\n"
    end
  end

  describe "info" do
    test "answers a promised package's own docs under its name, with nothing to steer at" do
      assert {:ok, %{name: "saxy", docs: text}, %{}} = Actions.run(:info, %{"name" => "saxy"})
      assert text =~ "# saxy "
      assert text =~ "\n# Saxy.XML\n"
      refute text =~ "# Applications this release carries"
    end

    test "refuses a name outside the promise, naming the accepted ones" do
      assert {:error, {{:unknown_package, detail}, %{action_verb: "render a package's docs"}}} =
               Actions.run(:info, %{"name" => "json"})

      assert detail =~ "nimble_csv"
    end
  end

  describe "run" do
    test "answers the action's result beside the call that produced it" do
      script = create!(segment())

      assert {:ok, answer, %{}} =
               Actions.run(:run, %{"script" => script.name, "action" => "ping"})

      assert answer == %{script: script.name, action: "ping", result: %{"pong" => true}}
    end

    test "passes args through to the action" do
      script = create!(segment())

      assert {:ok, %{result: %{"url" => "https://hex.pm"}}, %{}} =
               Actions.run(:run, %{
                 "script" => script.name,
                 "action" => "fetch",
                 "args" => %{"url" => "https://hex.pm"}
               })
    end

    test "forwards the runner's refusal rather than shaping it here" do
      script = create!(segment())

      assert {:error, {{:invalid_args, detail}, %{action_verb: "run a script"}}} =
               Actions.run(:run, %{"script" => script.name, "action" => "fetch"})

      assert detail =~ "url"
    end
  end

  describe "the wrong-typed twins" do
    test "answer a message for a non-string script, on both actions that take one" do
      assert {:error, {{:wrong_type, %{key: "script", got: 123}}, _ctx}} =
               Actions.run(:describe, %{"script" => 123})

      assert {:error, {{:wrong_type, %{key: "script", got: 123}}, _ctx}} =
               Actions.run(:run, %{"script" => 123, "action" => "ping"})
    end

    test "answer a message for a non-string action" do
      assert {:error, {{:wrong_type, %{key: "action", got: ["ping"]}}, _ctx}} =
               Actions.run(:run, %{"script" => "hex", "action" => ["ping"]})
    end

    test "answer a message for args that are not an object" do
      assert {:error, {{:wrong_type, %{key: "args", got: "url=x"}}, _ctx}} =
               Actions.run(:run, %{"script" => "hex", "action" => "fetch", "args" => "url=x"})
    end

    test "answer a message for a non-string package name" do
      assert {:error, {{:wrong_type, %{key: "name", got: 7}}, _ctx}} =
               Actions.run(:info, %{"name" => 7})
    end

    test "answer a message for a non-boolean code flag" do
      script = create!(segment())

      assert {:error, {{:wrong_type, %{key: "code", got: "yes"}}, _ctx}} =
               Actions.run(:describe, %{"script" => script.name, "code" => "yes"})
    end
  end

  defp segment, do: "Tool#{System.unique_integer([:positive])}"

  defp create!(segment) do
    on_exit(fn -> Compiler.purge(Module.concat(["Script", segment])) end)

    assert {:ok, script} = Scripts.create(code(segment))
    script
  end

  defp code(segment) do
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
      def declarations, do: %{hosts: [], url_action: nil, secrets: []}

      @impl true
      def run(:ping, _args, _context), do: {:ok, %{"pong" => true}}
      def run(:fetch, %{"url" => url}, _context), do: {:ok, %{"url" => url}}
    end
    """
  end
end
