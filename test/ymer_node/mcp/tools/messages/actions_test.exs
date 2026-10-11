defmodule YmerNode.Mcp.Tools.Messages.ActionsTest do
  @moduledoc """
  The boundary's own cases go through the application's `YmerNode.Messages`
  process, which every test module shares, so each case names its threads and
  handles with a number of its own and asserts on those alone — the thread
  index may hold any other module's threads. That is what keeps the module
  `async: true`.
  """
  use ExUnit.Case, async: true

  alias YmerNode.Mcp.Tools.Messages.Actions

  setup do
    n = System.unique_integer([:positive])
    %{thread: "thread-#{n}", dev: "dev-#{n}", tester: "tester-#{n}"}
  end

  describe "send, check and read" do
    test "a message sent is checked once and read any number of times",
         %{thread: thread, dev: dev, tester: tester} do
      message = %{"as" => dev, "thread" => thread, "body" => "x1 is ready"}
      assert {:ok, %{id: id, thread: ^thread}, %{}} = Actions.run(:send, message)

      read = %{"thread" => thread, "last" => 5}
      assert {:ok, %{threads: [%{messages: [%{id: ^id}]}]}, %{}} = Actions.run(:read, read)

      check = %{"as" => tester, "thread" => thread}
      assert {:ok, %{messages: [%{id: ^id, handle: ^dev}]}, %{}} = Actions.run(:check, check)
      assert {:ok, %{notice: _}, %{}} = Actions.run(:check, check)
    end

    test "a bare check lists the handle's threads with unread mail",
         %{thread: thread, dev: dev, tester: tester} do
      {:ok, _joined, %{}} = Actions.run(:check, %{"as" => tester, "thread" => thread})
      {:ok, _sent, %{}} = Actions.run(:send, %{"as" => dev, "thread" => thread, "body" => "hi"})

      assert {:ok, %{threads: [%{thread: ^thread, unread: 1}]}, %{}} =
               Actions.run(:check, %{"as" => tester})
    end

    test "the thread index holds the thread", %{thread: thread, dev: dev} do
      {:ok, _sent, %{}} = Actions.run(:send, %{"as" => dev, "thread" => thread, "body" => "hi"})

      assert {:ok, %{threads: rows}, %{}} = Actions.run(:read, %{})
      assert Enum.any?(rows, &(&1.thread == thread))
    end

    test "renders a refusal under the send verb, the body counted in bytes",
         %{thread: thread, dev: dev} do
      body = String.duplicate("ä", 4_097)

      assert {:error, {{:body_too_large, detail}, %{action_verb: "send a message"}}} =
               Actions.run(:send, %{"as" => dev, "thread" => thread, "body" => body})

      assert detail =~ "8194 bytes"
    end
  end

  describe "the wrong-typed twins" do
    test "answer an error message for a non-string as on send and check" do
      for action <- [:send, :check] do
        data = %{"as" => 7, "thread" => "t", "body" => "b"}
        assert {:error, {{:wrong_type, %{key: "as"}}, _ctx}} = Actions.run(action, data)
      end
    end

    test "answer an error message for each other wrong-typed key send takes" do
      for {key, value} <- [{"thread", 1}, {"body", %{}}] do
        data = Map.put(%{"as" => "a", "thread" => "t", "body" => "b"}, key, value)

        assert {:error, {{:wrong_type, %{key: ^key}}, %{action_verb: "send a message"}}} =
                 Actions.run(:send, data)
      end
    end

    test "answer an error message for a wrong-typed thread on check" do
      assert {:error, {{:wrong_type, %{key: "thread"}}, %{action_verb: "check messages"}}} =
               Actions.run(:check, %{"as" => "a", "thread" => ["t"]})
    end

    test "answer an error message for each wrong-typed key read takes" do
      for {key, value} <- [
            {"thread", 1},
            {"thread", ["t", 2]},
            {"last", "5"},
            {"before", "9"},
            {"since", 60}
          ] do
        assert {:error, {{:wrong_type, %{key: ^key}}, %{action_verb: "read messages"}}} =
                 Actions.run(:read, %{key => value})
      end
    end
  end
end
