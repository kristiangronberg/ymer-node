defmodule YmerNode.Schedules.Lifetime do
  @moduledoc """
  A schedule's lifetime — how far into the future it keeps firing — read from what
  a caller gives `add` or `update` into the one instant it ends.

  Every schedule ends. A missing lifetime is the ceiling, 90 days, and a longer
  one is cut to it: nothing is refused for being long, because the node can
  serve the request and the answer states the end it set. The ceiling is a bound
  against accidents — a schedule nobody remembers, firing for ever.

  ## The grammar

  One ISO-8601 field. A span starts with `P` — `P30D`, `PT12H`, `P2W`, `P1M` —
  and runs from the moment of the call. Anything else is an instant: with an
  offset or `Z` it means exactly that; without one it is read in the node's time
  zone, the zone the cron expression is read in. A bare date is refused, because
  whether it means the start of that day or its end is a guess.

  An offset-less instant the clock passes twice — in the hour a fall-back
  repeats — is its first pass, as it is for a cron expression
  (`YmerNode.Schedules.Cron`). One the clock never shows — in the hour a
  spring-forward skips — is refused, with a hint to give an offset.

  A lifetime that ends at or before the call is refused rather than stored as a
  schedule expired the moment it exists: a span of nothing, a negative span or
  an instant already past is a mistake best found at the keyboard.

  The end is computed in UTC and truncated to the second, which is how the
  schedule's row holds it.
  """

  @ceiling_days 90

  @doc """
  The instant a lifetime given at `now` ends, in UTC — `nil` meaning the ceiling.

  ## Examples

      iex> YmerNode.Schedules.Lifetime.ends_at(nil, ~U[2026-10-01 00:00:00Z], "Etc/UTC")
      {:ok, ~U[2026-12-30 00:00:00Z]}

      iex> YmerNode.Schedules.Lifetime.ends_at("P30D", ~U[2026-10-01 00:00:00Z], "Etc/UTC")
      {:ok, ~U[2026-10-31 00:00:00Z]}

      iex> YmerNode.Schedules.Lifetime.ends_at("P1Y", ~U[2026-10-01 00:00:00Z], "Etc/UTC")
      {:ok, ~U[2026-12-30 00:00:00Z]}

      iex> YmerNode.Schedules.Lifetime.ends_at("2026-10-02T12:00:00+03:00", ~U[2026-10-01 00:00:00Z], "Etc/UTC")
      {:ok, ~U[2026-10-02 09:00:00Z]}

  """
  def ends_at(nil, %DateTime{} = now, zone) when is_binary(zone), do: {:ok, ceiling(now)}

  def ends_at(lifetime, %DateTime{} = now, zone) when is_binary(lifetime) and is_binary(zone) do
    given = String.trim(lifetime)

    with {:ok, instant} <- read(given, now, zone),
         ends_at = instant |> DateTime.shift_zone!("Etc/UTC") |> earliest(ceiling(now)),
         :ok <- check_future(given, ends_at, now) do
      {:ok, ends_at}
    end
  end

  defp read("P" <> _rest = span, now, _zone) do
    case Duration.from_iso8601(span) do
      {:ok, duration} -> {:ok, DateTime.shift(now, duration)}
      {:error, _reason} -> refuse(span, "is not an ISO-8601 span" <> grammar())
    end
  end

  defp read(instant, _now, zone) do
    case DateTime.from_iso8601(instant) do
      {:ok, at, _offset} -> {:ok, at}
      {:error, :missing_offset} -> local(instant, zone)
      {:error, _reason} -> not_an_instant(instant)
    end
  end

  defp local(instant, zone) do
    with {:ok, naive} <- NaiveDateTime.from_iso8601(instant) do
      case DateTime.from_naive(naive, zone) do
        {:ok, at} ->
          {:ok, at}

        {:ambiguous, first_pass, _second_pass} ->
          {:ok, first_pass}

        {:gap, _before, _after} ->
          refuse(
            instant,
            "never shows on a clock in #{zone} — the " <>
              "clock skips that hour; give an offset, or Z"
          )
      end
    end
  end

  defp not_an_instant(given) do
    case Date.from_iso8601(given) do
      {:ok, _date} ->
        refuse(
          given,
          "is a date with no time — the start of that day or its end would " <>
            "be a guess; give a time too, such as #{given}T23:59:00"
        )

      {:error, _reason} ->
        refuse(given, "is neither an ISO-8601 span nor a date-time" <> grammar())
    end
  end

  defp check_future(given, instant, now) do
    if DateTime.compare(instant, now) == :gt do
      :ok
    else
      refuse(given, "ends at or before now; a lifetime reaches into the future")
    end
  end

  defp ceiling(now), do: now |> DateTime.add(@ceiling_days, :day) |> DateTime.truncate(:second)

  defp earliest(instant, ceiling) do
    if DateTime.compare(instant, ceiling) == :gt,
      do: ceiling,
      else: DateTime.truncate(instant, :second)
  end

  defp refuse(given, why), do: {:error, {:invalid_lifetime, "#{given} #{why}"}}

  defp grammar do
    " — give a span such as P30D or PT12H, or a date-time such as " <>
      "2026-12-24T18:00:00, or 2026-12-24T18:00:00+02:00 with an offset"
  end
end
