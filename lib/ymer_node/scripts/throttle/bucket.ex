defmodule YmerNode.Scripts.Throttle.Bucket do
  @moduledoc """
  A throttle's token bucket as a value: a rate per minute, a burst, the tokens it
  holds and the instant it last counted them.

  Every function that needs the time takes it as an argument — a
  `System.monotonic_time(:millisecond)` instant, which `YmerNode.Scripts.Throttle`
  passes — so the arithmetic a throttle's waits and refusals rest on is proven
  here without a clock. There is no tick: a bucket is refilled from the elapsed
  time whenever it is read, so an idle throttle costs nothing between requests,
  and its tokens are a float, because a rate per minute refills by fractions.
  """

  @type t :: %__MODULE__{
          rate: pos_integer(),
          burst: pos_integer(),
          tokens: float(),
          at: integer()
        }

  @enforce_keys [:rate, :burst, :tokens, :at]
  defstruct [:rate, :burst, :tokens, :at]

  @minute 60_000

  @doc """
  A full bucket at `now`.

  ## Examples

      iex> YmerNode.Scripts.Throttle.Bucket.new(60, 2, 0)
      %YmerNode.Scripts.Throttle.Bucket{rate: 60, burst: 2, tokens: 2.0, at: 0}

  """
  def new(rate, burst, now)
      when is_integer(rate) and rate > 0 and is_integer(burst) and burst > 0 and is_integer(now) do
    %__MODULE__{rate: rate, burst: burst, tokens: burst + 0.0, at: now}
  end

  @doc """
  The bucket at `now`: what the elapsed time refilled, never more than the burst.
  An instant earlier than the last one counts no time at all.

  ## Examples

      iex> bucket = %YmerNode.Scripts.Throttle.Bucket{rate: 60, burst: 2, tokens: 0.0, at: 0}
      iex> YmerNode.Scripts.Throttle.Bucket.refill(bucket, 1_500).tokens
      1.5
      iex> YmerNode.Scripts.Throttle.Bucket.refill(bucket, 10_000).tokens
      2.0

  """
  def refill(%__MODULE__{} = bucket, now) when is_integer(now) do
    elapsed = max(now - bucket.at, 0)
    tokens = min(bucket.burst + 0.0, bucket.tokens + elapsed * bucket.rate / @minute)

    %{bucket | tokens: tokens, at: max(now, bucket.at)}
  end

  @doc """
  The bucket at `now` under new parameters: refilled at the rate it had until
  now, then held to the new burst. A throttle's parameters arrive with every
  request, so this is how a changed declaration takes effect without losing what
  the old one had counted.

  ## Examples

      iex> bucket = %YmerNode.Scripts.Throttle.Bucket{rate: 60, burst: 2, tokens: 2.0, at: 0}
      iex> YmerNode.Scripts.Throttle.Bucket.configure(bucket, 30, 1, 0)
      %YmerNode.Scripts.Throttle.Bucket{rate: 30, burst: 1, tokens: 1.0, at: 0}

  """
  def configure(%__MODULE__{} = bucket, rate, burst, now)
      when is_integer(rate) and rate > 0 and is_integer(burst) and burst > 0 do
    refilled = refill(bucket, now)

    %{refilled | rate: rate, burst: burst, tokens: min(refilled.tokens, burst + 0.0)}
  end

  @doc """
  How long, in milliseconds, until the bucket holds a token for a request with
  `ahead` requests waiting in front of it — `0` when it holds one now.

  An estimate, and a conservative one: every request ahead is counted as taking
  its token and none as leaving. Rounded up, so a wait it names is never short.

  ## Examples

      iex> bucket = %YmerNode.Scripts.Throttle.Bucket{rate: 60, burst: 2, tokens: 1.5, at: 0}
      iex> YmerNode.Scripts.Throttle.Bucket.wait(bucket, 0)
      0
      iex> YmerNode.Scripts.Throttle.Bucket.wait(bucket, 1)
      500
      iex> YmerNode.Scripts.Throttle.Bucket.wait(bucket, 100)
      99500

  """
  def wait(%__MODULE__{} = bucket, ahead) when is_integer(ahead) and ahead >= 0 do
    missing = ahead + 1 - bucket.tokens

    if missing <= 0, do: 0, else: ceil(missing * @minute / bucket.rate)
  end

  @doc "Whether the bucket holds a whole token."
  def available?(%__MODULE__{tokens: tokens}), do: tokens >= 1

  @doc """
  The bucket with one token spent — only ever a bucket `available?/1` answers
  true for.

  ## Examples

      iex> bucket = %YmerNode.Scripts.Throttle.Bucket{rate: 60, burst: 2, tokens: 1.5, at: 0}
      iex> YmerNode.Scripts.Throttle.Bucket.take(bucket).tokens
      0.5

  """
  def take(%__MODULE__{tokens: tokens} = bucket) when tokens >= 1,
    do: %{bucket | tokens: tokens - 1}
end
