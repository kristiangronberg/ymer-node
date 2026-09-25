defmodule YmerNode.Schedules.LastRunTest do
  use ExUnit.Case, async: true

  alias YmerNode.Schedules.LastRun

  doctest LastRun

  describe "outcome/1" do
    test "groups every reason the runner answers into one of four outcomes" do
      grouped = %{
        "refused" => [
          :not_found,
          :not_accepted,
          :not_loaded,
          :unknown_action,
          :invalid_schema,
          :invalid_args
        ],
        "error" => [
          :script_error,
          :script_raised,
          :script_exited,
          :bad_return,
          :result_not_encodable
        ],
        "timeout" => [:timeout]
      }

      for {outcome, reasons} <- grouped, reason <- reasons do
        assert LastRun.outcome({:error, {reason, "detail"}}) == outcome, inspect(reason)
      end
    end
  end

  describe "attrs/3" do
    test "cuts a long message short, marking the cut" do
      detail = String.duplicate("x", 600)

      %{last_message: message} =
        LastRun.attrs({:error, {:script_error, detail}}, ~U[2026-09-26 07:00:00Z], 5)

      assert String.length(message) == 500
      assert String.ends_with?(message, "…")
    end

    test "truncates the firing's moment to the second the row holds" do
      %{last_fired_at: fired_at} = LastRun.attrs({:ok, %{}}, ~U[2026-09-26 07:00:00.123456Z], 5)

      assert fired_at == ~U[2026-09-26 07:00:00Z]
    end
  end
end
