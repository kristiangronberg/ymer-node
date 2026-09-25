defmodule YmerNode.Mcp.Tools.Schedules.ActionsTest do
  @moduledoc """
  The boundary's own cases: they go through `YmerNode.Schedules` and create the
  scripts they schedule, so the sandbox owns them and the module is not async;
  each fixture purges its own tree.

  What this file is for, beyond the happy paths, is the wrong-typed twins and
  the optional keys: `YmerNode.Schedules` guards its inputs, so without them a
  wire call carrying `name: 7` or `args: "x"` would raise `FunctionClauseError`
  and tell the caller nothing it could act on.
  """
  use YmerNode.DataCase

  alias YmerNode.Mcp.Tools.Schedules.Actions
  alias YmerNode.Scripts
  alias YmerNode.Scripts.Compiler

  describe "add" do
    test "answers the schedule it added" do
      script = create!(segment())

      assert {:ok, entry, %{}} = Actions.run(:add, data(script))
      assert %{name: "morning-report", state: "active", action: "ping"} = entry
    end

    test "takes args and a lifetime, and a null for either as left out" do
      script = create!(segment())

      fetching =
        Map.merge(%{data(script) | "action" => "fetch"}, %{
          "args" => %{"url" => "https://hex.pm"},
          "lifetime" => "P30D"
        })

      assert {:ok, %{args: %{"url" => "https://hex.pm"}}, %{}} = Actions.run(:add, fetching)

      nulls = Map.merge(data(script, "second"), %{"args" => nil, "lifetime" => nil})
      assert {:ok, _entry, %{}} = Actions.run(:add, nulls)
    end

    test "renders a refusal under the add verb" do
      script = create!(segment())

      assert {:error, {{:invalid_cron_expression, _detail}, %{action_verb: "add a schedule"}}} =
               Actions.run(:add, %{data(script) | "cron_expression" => "* * *"})
    end
  end

  describe "list, update and remove" do
    test "list answers a count and every schedule" do
      script = create!(segment())
      {:ok, _entry, %{}} = Actions.run(:add, data(script))

      assert {:ok, %{count: 1, schedules: [%{name: "morning-report"}]}, %{}} =
               Actions.run(:list, %{})
    end

    test "update changes what it is given" do
      script = create!(segment())
      {:ok, _entry, %{}} = Actions.run(:add, data(script))

      assert {:ok, %{cron_expression: "30 8 * * *"}, %{}} =
               Actions.run(:update, %{
                 "name" => "morning-report",
                 "cron_expression" => "30 8 * * *"
               })
    end

    test "remove names what went, and refuses what is not there" do
      script = create!(segment())
      {:ok, _entry, %{}} = Actions.run(:add, data(script))

      assert {:ok, %{removed: "morning-report"}, %{}} =
               Actions.run(:remove, %{"name" => "morning-report"})

      assert {:error, {{:not_found, _detail}, %{action_verb: "remove a schedule"}}} =
               Actions.run(:remove, %{"name" => "morning-report"})
    end
  end

  describe "the wrong-typed twins" do
    test "answer a message for a non-string name on every action that takes one" do
      for action <- [:add, :update, :remove] do
        data = %{
          "name" => 7,
          "script" => "hex",
          "action" => "ping",
          "cron_expression" => "@daily"
        }

        assert {:error, {{:wrong_type, %{key: "name"}}, _ctx}} = Actions.run(action, data)
      end
    end

    test "answer a message for each other wrong-typed key add takes" do
      base = %{
        "name" => "n",
        "script" => "hex",
        "action" => "ping",
        "cron_expression" => "@daily"
      }

      for {key, value} <- [
            {"script", 1},
            {"action", 1},
            {"cron_expression", 1},
            {"args", "x"},
            {"lifetime", 30}
          ] do
        assert {:error, {{:wrong_type, %{key: ^key}}, %{action_verb: "add a schedule"}}} =
                 Actions.run(:add, Map.put(base, key, value))
      end
    end

    test "answer a message for wrong-typed optional keys on update" do
      for {key, value} <- [{"cron_expression", 1}, {"args", []}, {"lifetime", 30}] do
        assert {:error, {{:wrong_type, %{key: ^key}}, %{action_verb: "update a schedule"}}} =
                 Actions.run(:update, %{"name" => "n", key => value})
      end
    end
  end

  defp segment, do: "SchedTool#{System.unique_integer([:positive])}"

  defp data(script, name \\ "morning-report") do
    %{
      "name" => name,
      "script" => script.name,
      "action" => "ping",
      "cron_expression" => "0 7 * * *"
    }
  end

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
