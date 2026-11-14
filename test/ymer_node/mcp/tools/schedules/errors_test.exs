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

  test "a library names the list that shows which names are scripts" do
    message = Errors.format({:not_runnable, "crosskey is a library: it never runs"})

    assert message ==
             "crosskey is a library: it never runs. `scripts list` shows which names are scripts."
  end

  test "a run refused for a library keeps the library's fix and names describe" do
    for reason <- [:library_missing, :library_broken, :library_out_of_range] do
      message = Errors.format({reason, "sync runs again once crosskey is held"})

      assert message =~ "sync runs again once crosskey is held"
      assert message =~ "`scripts describe`"
    end
  end
end
