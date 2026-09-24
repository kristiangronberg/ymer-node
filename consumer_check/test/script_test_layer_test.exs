defmodule ConsumerCheck.ScriptTestLayerTest do
  use ExUnit.Case, async: false

  alias YmerNode.Script.Context
  alias YmerNode.Script.Test, as: ScriptTest
  alias YmerNode.Scripts.Throttle

  setup {YmerNode.Script.Test, :start_run_tree}

  test "the node's application is not running here" do
    started = Enum.map(Application.started_applications(), &elem(&1, 0))

    refute :ymer_node in started
  end

  test "a script declaring a throttle and a secret runs through the stub" do
    compiled = ScriptTest.compile_script("scripts/throttled.exs")
    ScriptTest.put_secrets(%{"PROBE_PASSWORD" => "probe-password"})
    Req.Test.stub(Context, fn conn -> Req.Test.json(conn, %{"value" => 42}) end)

    context =
      ScriptTest.context(
        secrets: ["PROBE_PASSWORD"],
        throttles: compiled.declarations.throttles
      )

    assert compiled.module.run(:get, %{}, context) == {:ok, %{"value" => 42}}
    assert [%{name: "probe"}] = Throttle.list()
  end

  test "the setup filled every key this project's configuration leaves unset" do
    assert Keyword.get(Context.request_options(), :plug) == {Req.Test, Context}
    assert YmerNode.Secrets.path() == Path.expand("tmp/secrets.env")
    assert Context.files_dir(ScriptTest.context()) == Path.expand("tmp/files")
    assert File.dir?(Path.expand("tmp/files"))
  end

  test "the zone database this project's configuration names is the one in use" do
    assert {:ok, _instant} = DateTime.shift_zone(~U[2026-09-20 10:00:00Z], "Europe/Helsinki")
  end
end
