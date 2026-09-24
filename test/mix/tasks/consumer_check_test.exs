defmodule Mix.Tasks.YmerNode.ConsumerCheckTest do
  @moduledoc """
  Covers the task's refusal of arguments only. What the task proves, it proves
  by running: it builds and tests a consumer project, which no case can do
  from inside a VM whose own application is running.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.YmerNode.ConsumerCheck

  describe "run/1" do
    test "refuses arguments instead of ignoring them" do
      assert_raise Mix.Error, ~r/takes no arguments/, fn ->
        ConsumerCheck.run(["--fast"])
      end
    end
  end
end
