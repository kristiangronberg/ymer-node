defmodule ConsumerCheck.HarnessTest do
  use ExUnit.Case, async: false

  alias YmerNode.Script.Context
  alias YmerNode.Script.Harness
  alias YmerNode.Scripts.Throttle

  setup do
    saved = Map.new([Context, YmerNode.Secrets], &{&1, Application.get_env(:ymer_node, &1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {owner, nil} -> Application.delete_env(:ymer_node, owner)
        {owner, config} -> Application.put_env(:ymer_node, owner, config)
      end)
    end)

    :ok
  end

  test "a live run's shape: the run tree under a supervisor the caller names, the keys pointed" do
    {:ok, supervisor} =
      Supervisor.start_link(Harness.run_tree(),
        strategy: :one_for_one,
        name: ConsumerCheck.RunTree
      )

    # The tree is linked to this test's process and goes down with it, pass or
    # fail, but after the test ends rather than before: waiting for it here
    # keeps the next module's setup from starting the same names while it is
    # still going down.
    on_exit(fn ->
      ref = Process.monitor(supervisor)
      assert_receive {:DOWN, ^ref, :process, ^supervisor, _reason}, 5_000
    end)

    :ok = Harness.put_request_plug({Req.Test, ConsumerCheck.HarnessTest})
    :ok = Harness.put_secrets_path("tmp/harness/secrets.env")
    :ok = Harness.put_files_dir("tmp/harness/files")
    Req.Test.stub(ConsumerCheck.HarnessTest, fn conn -> Req.Test.json(conn, %{}) end)

    context = %Context{
      script: "harness",
      action: :get,
      secrets: [],
      throttles: %{"harness" => %{rate: 60, burst: 2}},
      deadline: System.monotonic_time(:millisecond) + 5_000
    }

    assert Process.whereis(ConsumerCheck.RunTree) == supervisor
    assert YmerNode.Secrets.path() == Path.expand("tmp/harness/secrets.env")
    assert Context.files_dir(context) == Path.expand("tmp/harness/files")

    assert {:ok, %Req.Response{status: 200}} =
             Context.request(context, url: "https://probe.test/", throttle: "harness")

    assert [%{name: "harness"}] = Throttle.list()
  end
end
