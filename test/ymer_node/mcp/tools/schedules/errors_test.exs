defmodule YmerNode.Mcp.Tools.Schedules.ErrorsTest do
  @moduledoc """
  Pure translation, so `async: true`.
  """
  use ExUnit.Case, async: true

  alias YmerNode.Mcp.Tools.Schedules.Errors

  test "an unaccepted script names both doors that can accept it" do
    message = Errors.format({:not_accepted, "hex is not accepted at its current code"})

    assert message =~ "script_author accept"
    assert message =~ "from the machine itself with `scripts accept`."
  end
end
