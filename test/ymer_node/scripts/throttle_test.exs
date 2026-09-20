defmodule YmerNode.Scripts.ThrottleTest do
  @moduledoc """
  Real time, against the running node's throttle supervisor and process
  registry, with a throttle name unique to each case — so no case meets another
  case's process, and none needs tearing down: a throttle nothing names again
  idles until the VM ends. Rates are hundreds a minute, so a token is
  milliseconds away; the arithmetic itself is
  `YmerNode.Scripts.Throttle.BucketTest`'s, where no clock runs.

  `record/2` is a cast, so a case that records statuses reads the throttle back
  with a call from the same process before it asserts: a call queues behind the
  casts that process has already sent.

  **Not async.** The closing cases lift this module's log level with
  `Logger.put_module_level/2`, so the info line a closing writes reaches the
  capture past the suite's `:warning` level, and a module's level is VM-global.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias YmerNode.Scripts.Throttle
  alias YmerNode.Scripts.Throttle.Error

  describe "take/3" do
    test "gives tokens while the bucket holds them, starting the throttle for its name" do
      name = name()

      assert :ok = Throttle.take(name, %{rate: 60, burst: 2}, deadline(1_000))
      assert :ok = Throttle.take(name, %{rate: 60, burst: 2}, deadline(1_000))

      assert %{burst: 2, rate: 60, waiters: 0, breaker: nil, tokens: tokens} = state(name)
      assert tokens < 1
    end

    test "refuses at once a wait the deadline cannot cover, naming the wait and the time left" do
      name = name()
      bucket = %{rate: 1, burst: 1}
      assert :ok = Throttle.take(name, bucket, deadline(1_000))

      {elapsed, result} = :timer.tc(fn -> Throttle.take(name, bucket, deadline(2_500)) end)

      assert {:error, %Error{reason: :deadline, throttle: ^name, message: message}} = result
      assert message =~ "about 60s needed, 2s left"
      assert elapsed < 500_000
    end

    test "lets a wait the deadline covers queue, and serves it when a token refills" do
      name = name()
      bucket = %{rate: 600, burst: 1}
      assert :ok = Throttle.take(name, bucket, deadline(1_000))

      {elapsed, result} = :timer.tc(fn -> Throttle.take(name, bucket, deadline(2_000)) end)

      assert result == :ok
      assert elapsed >= 50_000
    end

    test "serves waiters in the order they arrived" do
      name = name()
      bucket = %{rate: 600, burst: 1}
      parent = self()
      assert :ok = Throttle.take(name, bucket, deadline(1_000))

      for {tag, queued} <- [first: 1, second: 2] do
        spawn(fn ->
          :ok = Throttle.take(name, bucket, deadline(5_000))
          send(parent, {:served, tag})
        end)

        assert wait_until(fn -> state(name).waiters == queued end)
      end

      assert_receive {:served, earlier}, 1_000
      assert_receive {:served, later}, 1_000
      assert {earlier, later} == {:first, :second}
    end

    @tag doc: """
         A run is killed at its deadline as a matter of course, so a waiter
         dying in the queue is the ordinary case. A failure means a token went
         to a dead process, and every run killed while it waited costs the next
         request a token.
         """
    test "drops a waiter whose process dies, and spends no token on it" do
      name = name()
      bucket = %{rate: 300, burst: 1}
      assert :ok = Throttle.take(name, bucket, deadline(1_000))

      waiter = spawn(fn -> Throttle.take(name, bucket, deadline(5_000)) end)
      assert wait_until(fn -> state(name).waiters == 1 end)

      Process.exit(waiter, :kill)
      assert wait_until(fn -> state(name).waiters == 0 end)

      Process.sleep(300)
      assert state(name).tokens == 1.0
    end

    @tag doc: """
         Suspending the throttle puts its drain ahead of the waiter's :DOWN in
         the mailbox, the order a run killed at its deadline meets when a
         token is due at the same moment. A failure means the drain handed
         the token to the dead waiter.
         """
    test "hands no token to a waiter whose :DOWN is still in the mailbox" do
      name = name()
      bucket = %{rate: 120, burst: 1}
      assert :ok = Throttle.take(name, bucket, deadline(1_000))

      waiter = spawn(fn -> Throttle.take(name, bucket, deadline(5_000)) end)
      assert wait_until(fn -> state(name).waiters == 1 end)

      [{pid, _value}] = Registry.lookup(YmerNode.Scripts.Throttles, name)
      :sys.suspend(pid)
      Process.sleep(600)
      Process.exit(waiter, :kill)
      assert wait_until(fn -> message_queue_len(pid) >= 2 end)
      :sys.resume(pid)

      assert %{waiters: 0, tokens: 1.0} = state(name)
    end
  end

  describe "take/3 — parameters arriving with a request" do
    test "a changed declaration is obeyed at once, and the breaker keeps its state" do
      name = name()
      breaker = %{threshold: 1, cooldown: 60_000}
      assert :ok = Throttle.take(name, %{rate: 60, burst: 3, breaker: breaker}, deadline(1_000))
      Throttle.record(name, 401)

      assert {:error, %Error{reason: :open}} =
               Throttle.take(name, %{rate: 30, burst: 1, breaker: breaker}, deadline(1_000))

      assert %{rate: 30, burst: 1, tokens: tokens, breaker: %{resumes_in: resumes_in}} =
               state(name)

      assert tokens <= 1.0
      assert is_integer(resumes_in)
    end

    test "a declaration that drops the breaker leaves an open one open, and listed open" do
      name = name()
      breaker = %{threshold: 1, cooldown: 60_000}
      assert :ok = Throttle.take(name, %{rate: 600, burst: 5, breaker: breaker}, deadline(1_000))
      Throttle.record(name, 401)

      assert {:error, %Error{reason: :open}} =
               Throttle.take(name, %{rate: 600, burst: 5}, deadline(1_000))

      assert %{breaker: %{threshold: nil, failures: 1, resumes_in: resumes_in}} = state(name)
      assert is_integer(resumes_in)
    end
  end

  describe "record/2 — the breaker" do
    test "opens at the threshold's consecutive 401, refusing at once and logging the opening" do
      name = name()
      throttle = %{rate: 600, burst: 5, breaker: %{threshold: 2, cooldown: 60_000}}
      assert :ok = Throttle.take(name, throttle, deadline(1_000))

      log =
        capture_log(fn ->
          Throttle.record(name, 401)
          Throttle.record(name, 401)
          assert %{breaker: %{resumes_in: resumes_in}} = state(name)
          assert is_integer(resumes_in)
        end)

      assert log =~ "throttle #{name} opened after 2 consecutive 401s"

      assert {:error, %Error{reason: :open, message: message}} =
               Throttle.take(name, throttle, deadline(1_000))

      assert message =~ "stopped sending after 2 consecutive 401s"
      assert message =~ "`ymer-node throttles reset #{name}`"
    end

    @tag doc: """
         A response to a request sent just before the breaker opened arrives
         after it. A failure means such a response changed the open breaker: a
         late 401 counted again and restarted the cooldown, or a late 200
         zeroed the count.
         """
    test "ignores a response that arrives after the breaker opened" do
      name = name()
      throttle = %{rate: 600, burst: 5, breaker: %{threshold: 2, cooldown: 60_000}}
      assert :ok = Throttle.take(name, throttle, deadline(1_000))

      {opened, _log} =
        with_log(fn ->
          Throttle.record(name, 401)
          Throttle.record(name, 401)
          state(name).breaker
        end)

      assert %{failures: 2, resumes_in: resumes_in} = opened
      Process.sleep(20)

      log =
        capture_log(fn ->
          Throttle.record(name, 401)
          Throttle.record(name, 200)
          assert %{breaker: %{failures: 2, resumes_in: still_open}} = state(name)
          assert still_open <= resumes_in - 20
        end)

      refute log =~ "opened after"
    end

    test "zeroes the count on any other status" do
      name = name()
      throttle = %{rate: 600, burst: 5, breaker: %{threshold: 2, cooldown: 60_000}}
      assert :ok = Throttle.take(name, throttle, deadline(1_000))

      Throttle.record(name, 401)
      Throttle.record(name, 200)
      Throttle.record(name, 401)

      assert %{breaker: %{failures: 1, resumes_in: nil}} = state(name)
    end

    test "answers every waiter at once when the breaker opens" do
      name = name()
      throttle = %{rate: 1, burst: 1, breaker: %{threshold: 1, cooldown: 60_000}}
      parent = self()
      assert :ok = Throttle.take(name, throttle, deadline(1_000))

      spawn(fn -> send(parent, {:answered, Throttle.take(name, throttle, deadline(120_000))}) end)
      assert wait_until(fn -> state(name).waiters == 1 end)

      Throttle.record(name, 401)

      assert_receive {:answered, {:error, %Error{reason: :open}}}, 1_000
      assert %{waiters: 0} = state(name)
    end

    test "closes after the cooldown with its count at zero, and logs how" do
      Logger.put_module_level(Throttle, :info)
      on_exit(fn -> Logger.delete_module_level(Throttle) end)

      name = name()
      throttle = %{rate: 600, burst: 5, breaker: %{threshold: 1, cooldown: 100}}
      assert :ok = Throttle.take(name, throttle, deadline(1_000))

      log =
        capture_log([level: :info], fn ->
          Throttle.record(name, 401)
          assert %{breaker: %{resumes_in: resumes_in}} = state(name)
          assert is_integer(resumes_in)
          assert wait_until(fn -> state(name).breaker.resumes_in == nil end)
        end)

      assert log =~ "throttle #{name} closed — the cooldown passed"
      assert %{breaker: %{failures: 0}} = state(name)
      assert :ok = Throttle.take(name, throttle, deadline(1_000))
    end

    test "counts nothing on a throttle declared without a breaker" do
      name = name()
      bucket = %{rate: 600, burst: 5}
      assert :ok = Throttle.take(name, bucket, deadline(1_000))

      for _attempt <- 1..3, do: Throttle.record(name, 401)

      assert %{breaker: nil} = state(name)
      assert :ok = Throttle.take(name, bucket, deadline(1_000))
    end
  end

  describe "reset/1" do
    test "closes an open breaker now, clears its count, and logs who closed it" do
      Logger.put_module_level(Throttle, :info)
      on_exit(fn -> Logger.delete_module_level(Throttle) end)

      name = name()
      throttle = %{rate: 600, burst: 5, breaker: %{threshold: 1, cooldown: 60_000}}
      assert :ok = Throttle.take(name, throttle, deadline(1_000))
      Throttle.record(name, 401)

      log = capture_log([level: :info], fn -> assert :ok = Throttle.reset(name) end)

      assert log =~ "throttle #{name} closed — an operator reset it"
      assert %{breaker: %{failures: 0, resumes_in: nil}} = state(name)
      assert :ok = Throttle.take(name, throttle, deadline(1_000))
    end

    test "refuses a name no request has started" do
      name = name()

      assert {:error, {:throttle_not_started, detail}} = Throttle.reset(name)
      assert detail == "no throttle #{name} has started on this node"
    end
  end

  describe "list/0" do
    test "answers the started throttles in name order" do
      [earlier, later] = Enum.sort([name(), name()])

      for name <- [later, earlier] do
        assert :ok = Throttle.take(name, %{rate: 60, burst: 1}, deadline(1_000))
      end

      names = Enum.map(Throttle.list(), & &1.name)
      assert Enum.find_index(names, &(&1 == earlier)) < Enum.find_index(names, &(&1 == later))
    end

    @tag doc: """
         The registry names a throttle from the moment its process starts, and
         a listing can reach it before the request that started it is served. A
         failure means a throttle in that moment had no bucket to report, and
         the listing crashed it under that request.
         """
    test "answers a throttle's bucket from the moment its process starts" do
      name = name()

      assert {:ok, _pid} =
               DynamicSupervisor.start_child(
                 YmerNode.Scripts.ThrottleSupervisor,
                 {Throttle, {name, %{rate: 60, burst: 2}}}
               )

      assert %{tokens: 2.0, burst: 2, rate: 60, waiters: 0, breaker: nil} = state(name)
    end
  end

  describe "attach/3" do
    test "a request naming no throttle passes through untouched" do
      plug = fn conn -> Plug.Conn.send_resp(conn, 200, "ok") end

      assert {:ok, %Req.Response{status: 200}} =
               Req.new(plug: plug, retry: false)
               |> Throttle.attach(%{}, deadline(1_000))
               |> Req.request(url: "http://throttle.test/")
    end

    test "refuses a throttle the declarations do not name, before anything is sent" do
      parent = self()

      plug = fn conn ->
        send(parent, :sent)
        Plug.Conn.send_resp(conn, 200, "ok")
      end

      assert {:error, %Error{reason: :undeclared, message: message}} =
               Req.new(plug: plug, retry: false)
               |> Throttle.attach(%{}, deadline(1_000))
               |> Req.request(url: "http://throttle.test/", throttle: "absent")

      assert message =~ "the throttle absent, which its declarations/0 does not name"
      refute_received :sent
    end

    @tag doc: """
         Pins the response step's place ahead of Req's own retry step, which is
         itself a response step: a step behind it sees only the last attempt's
         status. A failure means the breaker is fed behind the retry again, and a
         script passing a retry policy meets a breaker that never counts the
         401s of any attempt but the last.
         """
    test "every attempt of a retried request pays a token and feeds its status to the breaker" do
      name = name()
      declared = %{name => %{rate: 600, burst: 5, breaker: %{threshold: 2, cooldown: 60_000}}}
      attempts = :counters.new(1, [])

      plug = fn conn ->
        :counters.add(attempts, 1, 1)
        status = if :counters.get(attempts, 1) == 1, do: 503, else: 401
        Plug.Conn.send_resp(conn, status, "")
      end

      request =
        Req.new(
          plug: plug,
          retry: fn _request, _answer -> true end,
          max_retries: 2,
          retry_delay: 0,
          retry_log_level: false
        )

      assert {:ok, %Req.Response{status: 401}} =
               request
               |> Throttle.attach(declared, deadline(5_000))
               |> Req.request(url: "http://throttle.test/", throttle: name)

      assert :counters.get(attempts, 1) == 3
      assert %{tokens: tokens, breaker: %{resumes_in: resumes_in}} = state(name)
      assert tokens < 3
      assert is_integer(resumes_in)
    end

    test "a transport error spends a token and leaves the count as it was" do
      name = name()
      declared = %{name => %{rate: 600, burst: 5, breaker: %{threshold: 2, cooldown: 60_000}}}
      plug = fn conn -> Req.Test.transport_error(conn, :econnrefused) end

      assert :ok = Throttle.take(name, declared[name], deadline(1_000))
      Throttle.record(name, 401)

      assert {:error, %Req.TransportError{}} =
               Req.new(plug: plug, retry: false)
               |> Throttle.attach(declared, deadline(1_000))
               |> Req.request(url: "http://throttle.test/", throttle: name)

      assert %{tokens: tokens, breaker: %{failures: 1, resumes_in: nil}} = state(name)
      assert tokens < 4
    end
  end

  defp name, do: "t-#{System.unique_integer([:positive])}"

  defp deadline(milliseconds), do: System.monotonic_time(:millisecond) + milliseconds

  defp state(name), do: Enum.find(Throttle.list(), &(&1.name == name))

  defp message_queue_len(pid), do: pid |> Process.info(:message_queue_len) |> elem(1)

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() ->
        true

      attempts == 0 ->
        false

      true ->
        Process.sleep(10)
        wait_until(fun, attempts - 1)
    end
  end
end
