defmodule YmerNode.Schedules.LifetimeTest do
  use ExUnit.Case, async: true

  alias YmerNode.Schedules.Lifetime

  doctest Lifetime

  @now ~U[2026-10-01 00:00:00Z]
  @helsinki "Europe/Helsinki"

  describe "ends_at/3" do
    test "reads an offset-less date-time in the zone it is given" do
      assert Lifetime.ends_at("2026-10-02T07:00:00", @now, @helsinki) ==
               {:ok, ~U[2026-10-02 04:00:00Z]}
    end

    test "resolves an offset-less time in the hour a fall-back repeats to its first pass" do
      assert Lifetime.ends_at("2026-10-25T03:30:00", @now, @helsinki) ==
               {:ok, ~U[2026-10-25 00:30:00Z]}
    end

    test "refuses an offset-less time in the hour a spring-forward skips, asking for an offset" do
      now = ~U[2027-03-01 00:00:00Z]

      assert {:error, {:invalid_lifetime, message}} =
               Lifetime.ends_at("2027-03-28T03:30:00", now, @helsinki)

      assert message =~ "give an offset, or Z"
    end

    test "refuses a bare date, asking for a time" do
      assert {:error, {:invalid_lifetime, message}} =
               Lifetime.ends_at("2026-12-31", @now, @helsinki)

      assert message =~ "give a time too, such as 2026-12-31T23:59:00"
    end

    test "refuses a lifetime that ends at or before now" do
      for given <- ["P0D", "P-1D", "2026-09-30T12:00:00Z"] do
        assert {:error, {:invalid_lifetime, message}} = Lifetime.ends_at(given, @now, @helsinki)
        assert message =~ "ends at or before now", given
      end
    end

    test "refuses what is neither a span nor a date-time, naming both shapes" do
      for given <- ["tomorrow", "P3X", "-P1D"] do
        assert {:error, {:invalid_lifetime, message}} = Lifetime.ends_at(given, @now, @helsinki)
        assert message =~ "give a span such as P30D", given
      end
    end
  end
end
