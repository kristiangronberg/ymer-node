defmodule YmerNode.Scripts.Throttle.BucketTest do
  use ExUnit.Case, async: true

  alias YmerNode.Scripts.Throttle.Bucket

  doctest Bucket

  describe "refill/2" do
    test "counts no stretch of time twice, and never runs backwards" do
      bucket = %Bucket{rate: 60, burst: 2, tokens: 0.0, at: 1_000}

      once = Bucket.refill(bucket, 1_500)

      assert once.tokens == 0.5
      assert Bucket.refill(once, 1_500).tokens == 0.5
      assert Bucket.refill(once, 1_200).tokens == 0.5
    end
  end

  describe "configure/4" do
    test "refills at the old rate up to now before the new parameters apply" do
      bucket = %Bucket{rate: 60, burst: 10, tokens: 0.0, at: 0}

      configured = Bucket.configure(bucket, 600, 10, 1_000)

      assert configured.tokens == 1.0
      assert configured.rate == 600
      assert Bucket.refill(configured, 1_100).tokens == 2.0
    end

    test "a raised burst adds no tokens of its own" do
      bucket = %Bucket{rate: 60, burst: 1, tokens: 1.0, at: 0}

      assert Bucket.configure(bucket, 60, 5, 0).tokens == 1.0
    end
  end

  describe "wait/2" do
    test "a request behind a hundred others on an empty 60-a-minute bucket waits 101 s" do
      bucket = %Bucket{rate: 60, burst: 2, tokens: 0.0, at: 0}

      assert Bucket.wait(bucket, 100) == 101_000
    end

    test "rounds a fraction of a millisecond up, so a wait it names is never short" do
      bucket = %Bucket{rate: 7, burst: 1, tokens: 0.0, at: 0}

      assert Bucket.wait(bucket, 0) == 8_572
    end
  end

  describe "take/1" do
    test "refuses a bucket without a whole token rather than going below zero" do
      bucket = %Bucket{rate: 60, burst: 2, tokens: 0.5, at: 0}

      refute Bucket.available?(bucket)
      assert_raise FunctionClauseError, fn -> Bucket.take(bucket) end
    end
  end
end
