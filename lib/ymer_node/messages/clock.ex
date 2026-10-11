defmodule YmerNode.Messages.Clock do
  @moduledoc """
  The times `YmerNode.Messages` reads and writes: the `since` a read takes, and
  every time an answer carries. The zone is handed in, never read here, so each
  rule below runs in a test against a zone with summer time.

  A `since` is one ISO-8601 field. A span starts with `P` — `PT1H`, `P1D` — and
  reaches that far back from the moment of the call; one that nets forward —
  `P-1D` — is refused. Anything else is an
  instant: with an offset or `Z` it means exactly that; without one it is read
  in the zone given, which the process passes as the
  [*node time zone*](docs/glossary.md#node-time-zone). An offset-less instant
  the clock passes twice — in the hour a fall-back repeats — is its first pass,
  as it is for a schedule's lifetime (`YmerNode.Schedules.Lifetime`); one the
  clock never shows — in the hour a spring-forward skips — is refused. A bare
  date is refused too, as neither shape.

  Every time an answer carries is ISO-8601 in the zone with its offset, the way
  `YmerNode.Schedules` renders.
  """

  @doc """
  The instant a `since` given at `now` names, in UTC — `nil` for no `since`.

  ## Examples

      iex> YmerNode.Messages.Clock.since("PT1H", ~U[2026-10-11 09:00:00Z], "Europe/Helsinki")
      {:ok, ~U[2026-10-11 08:00:00Z]}

      iex> YmerNode.Messages.Clock.since("2026-10-11T09:00:00", ~U[2026-10-11 12:00:00Z], "Europe/Helsinki")
      {:ok, ~U[2026-10-11 06:00:00Z]}

      iex> YmerNode.Messages.Clock.since("2026-10-11T09:00:00Z", ~U[2026-10-11 12:00:00Z], "Europe/Helsinki")
      {:ok, ~U[2026-10-11 09:00:00Z]}

      iex> YmerNode.Messages.Clock.since(nil, ~U[2026-10-11 12:00:00Z], "Europe/Helsinki")
      {:ok, nil}

  """
  def since(nil, %DateTime{}, zone) when is_binary(zone), do: {:ok, nil}

  def since("P" <> _rest = span, %DateTime{} = now, zone) when is_binary(zone) do
    case Duration.from_iso8601(span) do
      {:ok, duration} -> back(span, DateTime.shift(now, Duration.negate(duration)), now)
      {:error, _reason} -> refuse(span, "is not an ISO-8601 span")
    end
  end

  def since(instant, %DateTime{}, zone) when is_binary(instant) and is_binary(zone) do
    case DateTime.from_iso8601(instant) do
      {:ok, at, _offset} -> {:ok, at}
      {:error, :missing_offset} -> local(instant, zone)
      {:error, _reason} -> neither(instant)
    end
  end

  @doc """
  `at` as ISO-8601 in `zone`, with the offset it has there — `nil` for no time.

  ## Examples

      iex> YmerNode.Messages.Clock.format(~U[2026-07-01 09:00:00Z], "Europe/Helsinki")
      "2026-07-01T12:00:00+03:00"

      iex> YmerNode.Messages.Clock.format(~U[2026-12-01 09:00:00Z], "Europe/Helsinki")
      "2026-12-01T11:00:00+02:00"

  """
  def format(nil, zone) when is_binary(zone), do: nil

  def format(%DateTime{} = at, zone) when is_binary(zone),
    do: at |> DateTime.shift_zone!(zone) |> DateTime.to_iso8601()

  defp back(span, at, now) do
    if DateTime.after?(at, now),
      do: refuse(span, "reaches forward from now; a since span reaches back"),
      else: {:ok, at}
  end

  defp local(instant, zone) do
    case NaiveDateTime.from_iso8601(instant) do
      {:ok, naive} -> in_zone(naive, instant, zone)
      {:error, _reason} -> neither(instant)
    end
  end

  defp in_zone(naive, instant, zone) do
    case DateTime.from_naive(naive, zone) do
      {:ok, at} -> {:ok, utc(at)}
      {:ambiguous, first_pass, _second_pass} -> {:ok, utc(first_pass)}
      {:gap, _before, _after} -> refuse(instant, "never shows on a clock in #{zone}")
    end
  end

  defp utc(at), do: DateTime.shift_zone!(at, "Etc/UTC")

  defp neither(given), do: refuse(given, "is neither an ISO-8601 span nor a date-time")

  defp refuse(given, why), do: {:error, {:invalid_since, "#{given} #{why}"}}
end
