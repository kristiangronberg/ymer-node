defmodule YmerNode.Mcp.Tools.ScriptAuthor.ActionsTest do
  @moduledoc """
  Goes through `YmerNode.Scripts`, so the sandbox owns it and the module is not
  async. Fixtures compile into the VM, so each registers its own purge and every
  segment is unique.

  As in `YmerNode.Mcp.Tools.Scripts.ActionsTest`, the wrong-typed twin cases are
  the ones a green `mix precommit` cannot stand in for: without them a wire call
  carrying `code: 7` raises `FunctionClauseError` out of the context's own guard
  and the caller is told nothing it can act on.
  """
  use YmerNode.DataCase

  alias YmerNode.Mcp.Tools.ScriptAuthor.Actions
  alias YmerNode.Scripts
  alias YmerNode.Scripts.Compiler

  describe "check" do
    test "reports what the code would become and stores nothing" do
      segment = segment()
      purge_on_exit(segment)

      assert {:ok, checked, hint_context} = Actions.run(:check, %{"code" => code(segment)})
      assert checked.name == Macro.underscore(segment)
      assert checked.contract == 1
      assert %{"ping" => %{write: false}} = checked.actions
      assert checked.existing == false
      assert hint_context == %{}
      assert Repo.aggregate(Scripts.Script, :count) == 0
    end

    test "forwards the compiler's refusal" do
      assert {:error, {{:missing_contract, _detail}, %{action_verb: "check code"}}} =
               Actions.run(:check, %{"code" => "defmodule Script.Bare do\nend\n"})
    end
  end

  describe "create" do
    test "stores the script and answers it in describe's own shape" do
      segment = segment()
      purge_on_exit(segment)

      assert {:ok, detail, hint_context} = Actions.run(:create, %{"code" => code(segment)})
      assert detail.name == Macro.underscore(segment)
      assert detail.origin == "authored"
      assert detail.accepted == true
      assert detail.loaded == true
      assert %{"fetch" => %{write: false}} = detail.actions
      assert hint_context == %{script: detail.name}
    end

    test "refuses a name that already exists" do
      segment = segment()
      purge_on_exit(segment)
      assert {:ok, _detail, _hint} = Actions.run(:create, %{"code" => code(segment)})

      assert {:error, {{:name_taken, _detail}, %{action_verb: "create a script"}}} =
               Actions.run(:create, %{"code" => code(segment)})
    end
  end

  describe "update" do
    test "replaces the code and answers the stored script" do
      segment = segment()
      purge_on_exit(segment)
      assert {:ok, before, _hint} = Actions.run(:create, %{"code" => code(segment)})

      reworded = String.replace(code(segment), "the #{segment} script", "reworded")

      assert {:ok, detail, _hint} =
               Actions.run(:update, %{"script" => before.name, "code" => reworded})

      assert detail.description == "reworded"
    end

    test "refuses code that derives to another name" do
      segment = segment()
      other = segment()
      purge_on_exit(segment)
      purge_on_exit(other)
      assert {:ok, stored, _hint} = Actions.run(:create, %{"code" => code(segment)})

      assert {:error, {{:name_mismatch, _detail}, %{action_verb: "update a script"}}} =
               Actions.run(:update, %{"script" => stored.name, "code" => code(other)})
    end
  end

  describe "accept" do
    test "marks stale code accepted and answers the script" do
      segment = segment()
      purge_on_exit(segment)
      assert {:ok, stored, _hint} = Actions.run(:create, %{"code" => code(segment)})

      Scripts.get(stored.name)
      |> elem(1)
      |> Scripts.Script.changeset(%{accepted_hash: "not the code hash"})
      |> Repo.update!()

      assert {:ok, detail, _hint} = Actions.run(:accept, %{"script" => stored.name})
      assert detail.accepted == true
    end
  end

  describe "remove" do
    test "deletes the script and names what went" do
      segment = segment()
      purge_on_exit(segment)
      assert {:ok, stored, _hint} = Actions.run(:create, %{"code" => code(segment)})

      assert {:ok, %{removed: name}, %{}} = Actions.run(:remove, %{"script" => stored.name})
      assert name == stored.name
      assert Repo.aggregate(Scripts.Script, :count) == 0
    end

    test "names the schedules that went with it" do
      segment = segment()
      purge_on_exit(segment)
      assert {:ok, stored, _hint} = Actions.run(:create, %{"code" => code(segment)})

      {:ok, _entry} =
        YmerNode.Schedules.add(%{
          name: "morning-report",
          script: stored.name,
          action: "ping",
          cron_expression: "0 7 * * *"
        })

      assert {:ok, %{removed: name, schedules: ["morning-report"]}, %{}} =
               Actions.run(:remove, %{"script" => stored.name})

      assert name == stored.name
    end

    test "refuses a script that is not there" do
      assert {:error, {{:not_found, _detail}, %{action_verb: "remove a script"}}} =
               Actions.run(:remove, %{"script" => "absent"})
    end
  end

  describe "the wrong-typed twins" do
    test "answer a message for non-string code" do
      assert {:error, {{:wrong_type, %{key: "code", got: 7}}, _ctx}} =
               Actions.run(:check, %{"code" => 7})

      assert {:error, {{:wrong_type, %{key: "code", got: 7}}, _ctx}} =
               Actions.run(:create, %{"code" => 7})

      assert {:error, {{:wrong_type, %{key: "code", got: 7}}, _ctx}} =
               Actions.run(:update, %{"script" => "hex", "code" => 7})
    end

    test "answer a message for a non-string script on every action that takes one" do
      for action <- [:update, :accept, :remove] do
        data = %{"script" => %{"name" => "hex"}, "code" => "x"}

        assert {:error, {{:wrong_type, %{key: "script"}}, _ctx}} = Actions.run(action, data)
      end
    end
  end

  defp segment, do: "Author#{System.unique_integer([:positive])}"

  defp purge_on_exit(segment) do
    on_exit(fn -> Compiler.purge(Module.concat(["Script", segment])) end)
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
