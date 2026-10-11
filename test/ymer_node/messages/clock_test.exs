defmodule YmerNode.Messages.ClockTest do
  use ExUnit.Case, async: true

  alias YmerNode.Messages.Clock

  doctest Clock

  @now ~U[2026-10-01 00:00:00Z]
  @helsinki "Europe/Helsinki"

  describe "since/3" do
    test "reads an offset-less date-time in the zone it is given" do
      assert Clock.since("2026-10-02T07:00:00", @now, @helsinki) ==
               {:ok, ~U[2026-10-02 04:00:00Z]}
    end

    test "honours an offset or Z, whatever the zone" do
      assert Clock.since("2026-10-02T07:00:00+02:00", @now, @helsinki) ==
               {:ok, ~U[2026-10-02 05:00:00Z]}

      assert Clock.since("2026-10-02T07:00:00Z", @now, @helsinki) ==
               {:ok, ~U[2026-10-02 07:00:00Z]}
    end

    test "resolves an offset-less time in the hour a fall-back repeats to its first pass" do
      assert Clock.since("2026-10-25T03:30:00", @now, @helsinki) ==
               {:ok, ~U[2026-10-25 00:30:00Z]}
    end

    test "refuses an offset-less time in the hour a spring-forward skips" do
      assert {:error, {:invalid_since, detail}} =
               Clock.since("2027-03-28T03:30:00", @now, @helsinki)

      assert detail == "2027-03-28T03:30:00 never shows on a clock in Europe/Helsinki"
    end

    test "refuses a span that reaches forward from now" do
      for span <- ["P-1D", "PT-1H"] do
        assert Clock.since(span, @now, @helsinki) ==
                 {:error,
                  {:invalid_since, "#{span} reaches forward from now; a since span reaches back"}}
      end
    end

    test "refuses what is neither a span nor a date-time, a bare date among them" do
      for given <- ["yesterday", "2026-10-02", "2026-13-45T00:00:00"] do
        assert Clock.since(given, @now, @helsinki) ==
                 {:error,
                  {:invalid_since, "#{given} is neither an ISO-8601 span nor a date-time"}}
      end

      assert Clock.since("Pfoo", @now, @helsinki) ==
               {:error, {:invalid_since, "Pfoo is not an ISO-8601 span"}}
    end
  end
end
