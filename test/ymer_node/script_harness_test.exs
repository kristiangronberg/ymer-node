defmodule YmerNode.ScriptHarnessTest do
  @moduledoc """
  The node's application runs in this suite, so the run tree's processes are
  already registered here: the cases read `run_tree/0` as a list and never
  start it. Starting it where no application runs is what
  `mix ymer_node.consumer_check` proves.

  **Not async**: the setters write VM-global application config — the
  `YmerNode.Script.Context` and `YmerNode.Secrets` entries — which
  `YmerNode.ScriptContextTest` and `YmerNode.SecretsTest` set too. The setup
  puts both entries back as it found them on exit, because the `Req.Test`
  plug every stubbed request in the suite relies on lives in one of them.
  """
  use ExUnit.Case, async: false

  alias YmerNode.Script.Context
  alias YmerNode.Script.Harness
  alias YmerNode.Secrets

  setup do
    saved = Harness.snapshot()
    on_exit(fn -> Harness.restore(saved) end)
    :ok
  end

  defp context do
    %Context{
      script: "fixture",
      action: :noop,
      secrets: [],
      throttles: %{},
      deadline: System.monotonic_time(:millisecond) + 5_000
    }
  end

  describe "run_tree/0" do
    test "names the throttles' process registry and supervisor and the compiler's task supervisor" do
      names = for {_module, options} <- Harness.run_tree(), do: Keyword.fetch!(options, :name)

      assert names == [
               YmerNode.Scripts.TaskSupervisor,
               YmerNode.Scripts.Throttles,
               YmerNode.Scripts.ThrottleSupervisor
             ]
    end

    @tag doc: """
         The run tree is transcribed from the node's own supervision tree, and
         this case compares `run_tree/0` with the application's children. A
         failure means the application's scripts children changed and the run
         tree did not, so a VM starting the run tree would no longer have what
         a run inside the node has. Change the run tree to match the
         application, never the assertion.
         """
    test "is the run of children the node's application starts, in its order" do
      tree = Harness.run_tree()
      children = YmerNode.Application.children()
      start = Enum.find_index(children, &(&1 == hd(tree)))

      assert is_integer(start)
      assert Enum.slice(children, start, length(tree)) == tree
    end
  end

  describe "put_request_plug/1" do
    test "puts the plug and keeps every other request option" do
      assert :ok = Harness.put_request_plug({Req.Test, :another_stub})

      assert Keyword.get(Context.request_options(), :plug) == {Req.Test, :another_stub}
      assert Keyword.get(Context.request_options(), :retry) == false
    end

    test "nil takes the plug off and keeps every other request option" do
      assert :ok = Harness.put_request_plug(nil)

      refute Keyword.has_key?(Context.request_options(), :plug)
      assert Keyword.get(Context.request_options(), :retry) == false
    end

    test "with no request options configured, puts the plug over the node's own" do
      config = Application.get_env(:ymer_node, Context, [])
      Application.put_env(:ymer_node, Context, Keyword.delete(config, :request_options))

      assert :ok = Harness.put_request_plug({Req.Test, Context})

      assert Context.request_options() ==
               [plug: {Req.Test, Context}, retry: false, receive_timeout: 15_000]
    end

    test "leaves the files directory where it was" do
      directory = Context.files_dir(context())

      assert :ok = Harness.put_request_plug(nil)

      assert Context.files_dir(context()) == directory
    end
  end

  describe "put_secrets_path/1" do
    test "points the secrets file at the path, expanded to an absolute one" do
      assert :ok = Harness.put_secrets_path("tmp/harness.env")

      assert Secrets.path() == Path.expand("tmp/harness.env")
    end

    test "points it when no secrets entry is configured at all" do
      Application.delete_env(:ymer_node, Secrets)

      assert :ok = Harness.put_secrets_path("/data/secrets.env")

      assert Secrets.path() == "/data/secrets.env"
    end
  end

  describe "put_files_dir/1" do
    test "points the files directory at the directory, expanded, and keeps the plug" do
      plug = Keyword.get(Context.request_options(), :plug)

      assert :ok = Harness.put_files_dir("tmp/harness_files")

      assert Context.files_dir(context()) == Path.expand("tmp/harness_files")
      assert Keyword.get(Context.request_options(), :plug) == plug
    end
  end
end
