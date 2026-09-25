defmodule YmerNode.Schedules.CronTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Crontab.CronExpression.Parser
  alias YmerNode.Schedules.Cron

  doctest Cron

  @helsinki "Europe/Helsinki"

  describe "parse/1" do
    test "accepts every nickname, each set to fire a repeated hour's first pass only" do
      for nickname <- ~w(@hourly @daily @midnight @weekly @monthly @yearly @annually) do
        assert {:ok, %{on_ambiguity: [:prior]}} = Cron.parse(nickname), nickname
      end
    end

    test "refuses a sixth, year field" do
      assert {:error, {:invalid_cron_expression, message}} = Cron.parse("0 0 * * * 2027")
      assert message =~ "has 6 fields"
    end

    test "refuses a nickname it does not know" do
      assert {:error, {:invalid_cron_expression, message}} = Cron.parse("@often")
      assert message =~ "@often is not a nickname this node knows"
    end

    test "refuses what the package cannot parse, with the package's own reason" do
      assert {:error, {:invalid_cron_expression, message}} = Cron.parse("61 * * * *")
      assert message =~ "Can't parse 61 as minute"
    end

    @tag doc: """
         The package parses a day of week 0 with `L` or `#` and then never
         finds a date for it: `0L` walks without end. A failure means such a
         schedule is stored, and its next firing is never found.
         """
    test "refuses a day of week 0 with L or #, and takes Sunday as 7 or SUN with them" do
      for expression <- ["0 7 * * 0#2", "0 7 * * 1,0L"] do
        assert {:error, {:invalid_cron_expression, message}} = Cron.parse(expression)
        assert message =~ "write Sunday as 7 or SUN", expression
      end

      for expression <- ["0 7 * * 7L", "0 7 * * SUN#2", "0 7 * * 0"] do
        assert {:ok, _cron} = Cron.parse(expression), expression
      end
    end
  end

  describe "next_firing/2" do
    @tag doc: """
         Pins the first-pass rule on the night the clock falls back in
         Helsinki, when 03:30 happens twice. A failure on the second assertion
         means a walk from just after the first pass lands on the second: a
         schedule set for 03:30 would fire twice that night.
         """
    test "in the hour a fall-back repeats, comes due on the first pass and then the next day" do
      {:ok, cron} = Cron.parse("30 3 * * *")

      first_pass = DateTime.shift_zone!(~U[2026-10-25 00:30:00Z], @helsinki)
      assert same?(Cron.next_firing(cron, first_pass), ~U[2026-10-25 00:30:00Z])

      just_after = DateTime.shift_zone!(~U[2026-10-25 00:31:00Z], @helsinki)
      assert same?(Cron.next_firing(cron, just_after), ~U[2026-10-26 01:30:00Z])
    end

    @tag doc: """
         The package's search includes the moment it starts from, so a walk
         that starts on 03:30's second pass answers that very minute. A
         failure means a scheduler that came up in that minute fires 03:30 a
         second time.
         """
    test "walked from the second pass itself, answers the next day" do
      {:ok, cron} = Cron.parse("30 3 * * *")
      second_pass = DateTime.shift_zone!(~U[2026-10-25 01:30:00Z], @helsinki)

      assert same?(Cron.next_firing(cron, second_pass), ~U[2026-10-26 01:30:00Z])
    end

    test "walks an every-minute cadence past the whole second pass" do
      {:ok, cron} = Cron.parse("* * * * *")
      second_pass_starts = DateTime.shift_zone!(~U[2026-10-25 01:00:00Z], @helsinki)

      assert same?(Cron.next_firing(cron, second_pass_starts), ~U[2026-10-25 02:00:00Z])
    end

    test "a time in the hour a spring-forward skips comes due the next day" do
      {:ok, cron} = Cron.parse("30 3 * * *")
      from = DateTime.shift_zone!(~U[2027-03-28 00:30:00Z], @helsinki)

      assert same?(Cron.next_firing(cron, from), ~U[2027-03-29 00:30:00Z])
    end

    test "answers :none for an expression that never comes due" do
      {:ok, cron} = Cron.parse("0 0 30 2 *")

      assert Cron.next_firing(cron, ~U[2026-09-26 00:00:00Z]) == :none
    end

    @tag doc: """
         The package parsed straight, past `parse/1`'s refusal, because this
         is the one expression known to walk without end. A failure that hangs
         means a walk has no deadline, and one schedule would stop every
         other one from firing.
         """
    test "answers :none, and logs the expression, when the walk gives out" do
      {:ok, cron} = Parser.parse("0 7 * * 0L")

      log =
        capture_log(fn ->
          assert Cron.next_firing(cron, ~U[2026-09-26 00:00:00Z]) == :none
        end)

      assert log =~ "The walk for cron expression 0 7 * * 0L"
    end
  end

  defp same?(%DateTime{} = at, %DateTime{} = utc), do: DateTime.compare(at, utc) == :eq
end
