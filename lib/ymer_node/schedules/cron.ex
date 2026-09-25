defmodule YmerNode.Schedules.Cron do
  @moduledoc """
  A schedule's cron expression: which ones the node accepts, and when one comes
  due next in the node's time zone. The `crontab` package parses and walks them;
  this module decides only what that package leaves open.

  ## What is accepted

  Exactly five fields — minute, hour, day of month, month, day of week — with
  numbers, ranges, steps, lists, day and month names, and `L`, `W` and `#`; or one
  of the nicknames `@hourly`, `@daily`, `@midnight`, `@weekly`, `@monthly`,
  `@yearly` and `@annually`. Five fields fire at most once a minute, which is as
  often as a schedule may.

  Four shapes the package would parse are refused — the first three before it
  sees them, the fourth on the values it reads.
  `@reboot` names an event, not a cadence. A sixth, year field would be a second
  way for a schedule to end, and its lifetime is the one bound. Fewer than five
  fields is a slip the package would silently pad with `*`: `* * *` typed for
  `0 7 * * *` would fire every minute for as long as the schedule lives. And a
  day of week `0` carrying `L` or `#` never comes due in the package's walk —
  `0L` walks without end and `0#2` answers that no date exists — so Sunday is
  written `7` or `SUN` with them.

  ## A clock that jumps

  Every expression is walked with `on_ambiguity: [:prior]`, set after the parse,
  because the package's nicknames come back without it. When the clock falls
  back and an hour occurs twice, a time in that hour comes due once, on its first
  pass, and a cadence of any density keeps the first pass of the hour and skips
  the second. When the clock springs forward, a time inside the missing hour
  does not come due that day. Both are small-hours misses on two days a year,
  met with the simplest rule that never fires anything twice.

  The package alone keeps that rule only for a walk that starts before the
  repeated hour. Its search includes the moment it starts from, so a walk that
  starts on a matching minute of the second pass answers that very minute, and
  `* * * * *` walked on a minute at a time would come due all through the
  second pass. So `next_firing/2` checks every answer the package gives: one
  that is the second pass of a repeated local time is walked past, a minute at
  a time, until the answer is a first pass or a time that does not repeat.
  Whoever asks, from whichever minute — `YmerNode.Schedules.Scheduler` after a
  restart or a changed expression, or `YmerNode.Schedules.list/0` — gets the
  same answer.

  ## A walk that gives out

  A walk runs in a task of its own under a deadline, and one that raises or runs
  past it answers `:none` and logs a warning naming the expression. The package
  has walks that never return, and one schedule's expression must not hold up
  the minute every other schedule fires in, or an answer that lists them.
  """
  require Logger

  alias Crontab.CronExpression
  alias Crontab.CronExpression.Composer
  alias Crontab.CronExpression.Parser
  alias Crontab.Scheduler

  @nicknames ~w(@hourly @daily @midnight @weekly @monthly @yearly @annually)
  @walk_deadline 1_000

  @doc """
  Parses a cron expression the node accepts, set to fire only the first pass of
  a repeated hour.

  ## Examples

      iex> {:ok, cron} = YmerNode.Schedules.Cron.parse("0 7 * * MON-FRI")
      iex> cron.on_ambiguity
      [:prior]

      iex> YmerNode.Schedules.Cron.parse("* * *")
      {:error, {:invalid_cron_expression, "* * * has 3 fields; a cron expression has exactly five — minute, hour, day of month, month, day of week"}}

      iex> YmerNode.Schedules.Cron.parse("@reboot")
      {:error, {:invalid_cron_expression, "@reboot names an event, not a cadence; give five fields or one of @hourly, @daily, @midnight, @weekly, @monthly, @yearly, @annually"}}

      iex> YmerNode.Schedules.Cron.parse("0 7 * * 0L")
      {:error, {:invalid_cron_expression, "0 7 * * 0L: write Sunday as 7 or SUN with L or # — a day of week 0 with them never comes due"}}

      iex> YmerNode.Schedules.Cron.parse("0 7 * * +0#2")
      {:error, {:invalid_cron_expression, "0 7 * * +0#2: write Sunday as 7 or SUN with L or # — a day of week 0 with them never comes due"}}

  """
  def parse(expression) when is_binary(expression) do
    trimmed = String.trim(expression)

    with :ok <- check_shape(trimmed),
         {:ok, cron} <- parsed(trimmed),
         :ok <- check_weekday(trimmed, cron.weekday) do
      {:ok, %{cron | on_ambiguity: [:prior]}}
    end
  end

  defp parsed(expression) do
    case Parser.parse(expression) do
      {:ok, cron} -> {:ok, cron}
      {:error, reason} -> {:error, {:invalid_cron_expression, "#{expression}: #{reason}"}}
    end
  end

  @doc """
  The first moment at or after `from` that the expression comes due, in `from`'s
  zone — `:none` when it never does, or when the walk gives out. A `from` with
  seconds past its minute has left that minute, so the answer is a later one,
  and the answer is never the second pass of a repeated local time.

  ## Examples

      iex> {:ok, cron} = YmerNode.Schedules.Cron.parse("0 7 * * *")
      iex> YmerNode.Schedules.Cron.next_firing(cron, ~U[2026-09-26 07:00:00Z])
      ~U[2026-09-26 07:00:00Z]
      iex> YmerNode.Schedules.Cron.next_firing(cron, ~U[2026-09-26 07:00:30Z])
      ~U[2026-09-27 07:00:00Z]

  """
  def next_firing(%CronExpression{} = cron, %DateTime{} = from) do
    walk = Task.async(fn -> guarded_walk(cron, from) end)

    case Task.yield(walk, @walk_deadline) || Task.shutdown(walk, :brutal_kill) do
      {:ok, {:ok, answer}} -> answer
      {:ok, {:raised, message}} -> gave_out(cron, "raised #{message}")
      _no_answer -> gave_out(cron, "found nothing within #{@walk_deadline} ms")
    end
  end

  defp guarded_walk(cron, from) do
    {:ok, walk(cron, from)}
  rescue
    exception -> {:raised, Exception.message(exception)}
  end

  defp walk(cron, from) do
    case Scheduler.get_next_run_date(cron, from) do
      {:ok, next} -> if second_pass?(next), do: walk(cron, one_minute_on(next)), else: next
      {:error, _never} -> :none
    end
  end

  defp second_pass?(%DateTime{} = at) do
    case DateTime.from_naive(DateTime.to_naive(at), at.time_zone) do
      {:ambiguous, first, _second} -> DateTime.compare(at, first) == :gt
      _one_instant -> false
    end
  end

  defp one_minute_on(at), do: DateTime.add(at, 60, :second)

  defp gave_out(cron, what) do
    Logger.warning(
      "The walk for cron expression #{Composer.compose(cron)} #{what}; " <>
        "it is treated as never coming due"
    )

    :none
  end

  defp check_shape("@reboot") do
    {:error, {:invalid_cron_expression, "@reboot names an event, not a cadence; " <> accepted()}}
  end

  defp check_shape("@" <> _rest = nickname) do
    if nickname in @nicknames do
      :ok
    else
      {:error,
       {:invalid_cron_expression, "#{nickname} is not a nickname this node knows; " <> accepted()}}
    end
  end

  defp check_shape(expression) do
    fields = String.split(expression)

    case length(fields) do
      5 ->
        :ok

      count ->
        {:error,
         {:invalid_cron_expression,
          "#{expression} has #{count} fields; a cron expression has exactly five — " <>
            "minute, hour, day of month, month, day of week"}}
    end
  end

  # Read off the parsed values rather than the text, because the package reads
  # `+0L`, `-0L` and `00#2` as day 0 too; `7` and `SUN` parse as 7.
  defp check_weekday(expression, weekday) do
    if Enum.any?(weekday, &(match?({:L, 0}, &1) or match?({:"#", 0, _nth}, &1))) do
      {:error,
       {:invalid_cron_expression,
        "#{expression}: write Sunday as 7 or SUN with L or # — a day of week 0 with them " <>
          "never comes due"}}
    else
      :ok
    end
  end

  defp accepted, do: "give five fields or one of " <> Enum.join(@nicknames, ", ")
end
