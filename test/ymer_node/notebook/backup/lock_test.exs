defmodule YmerNode.Notebook.Backup.LockTest do
  @moduledoc """
  The lock is a shared, named singleton started by the application supervisor, so
  these tests are `async: false` and release whatever they acquire.
  """
  use ExUnit.Case, async: false

  alias YmerNode.Notebook.Backup.Lock

  describe "with_lock/2" do
    test "runs the function and returns its value when the lock is free" do
      assert {:ok, 42} = Lock.with_lock(:backup, fn -> {:ok, 42} end)
      assert Lock.current() == :idle
    end

    @tag doc: """
         A failure here means the second caller is blocking on the mailbox — the
         wrong semantics. The work runs in the caller precisely so a second
         operation is told to retry rather than queued behind a multi-second one.
         """
    test "rejects a second op while one is in progress" do
      test = self()

      task =
        Task.async(fn ->
          Lock.with_lock(:backup, fn ->
            send(test, :holding)
            assert_receive :release
            :done
          end)
        end)

      assert_receive :holding
      assert {:error, :operation_in_progress} = Lock.with_lock(:restore, fn -> :nope end)
      send(task.pid, :release)
      assert :done = Task.await(task)
      assert Lock.current() == :idle
    end

    @tag doc: """
         The release sits in an `after`, so a raising capture or restore still
         frees the singleton. A failure wedges every later operation in the run.
         """
    test "releases the lock even if the work raises" do
      assert_raise RuntimeError, fn -> Lock.with_lock(:backup, fn -> raise "boom" end) end
      assert Lock.current() == :idle
    end
  end

  describe "crash safety" do
    @tag doc: """
         The holder monitor is what keeps a crashed capture or restore from
         wedging the singleton until the application restarts. A failure means the
         `:DOWN` clause stopped matching on the holder's own monitor ref.
         """
    test "auto-releases when the holder process dies" do
      test = self()

      pid =
        spawn(fn ->
          :ok = GenServer.call(Lock, {:acquire, :backup})
          send(test, :acquired)
          Process.sleep(:infinity)
        end)

      assert_receive :acquired
      assert {:error, :operation_in_progress} = GenServer.call(Lock, {:acquire, :restore})
      Process.exit(pid, :kill)
      assert :ok = acquire_within(50)
      :ok = GenServer.call(Lock, :release)
    end
  end

  describe "when the lock is alive and not answering" do
    @tag :capture_log
    @tag doc: """
         The other way an acquire fails to come back: the process is there and
         does not answer within its call timeout. `GenServer.call/3` gives up, but
         the request stays in the mailbox, and a lock that answers late grants it
         to a caller that has already been told the lock was unreachable — a hold
         with nothing running behind it, which every later operation reads as
         `:operation_in_progress` until the holder dies. `:sys.suspend/1` is the
         deterministic way into that state. A failure here means the timed-out
         acquire stopped cancelling itself: the lock answers `{:busy, :backup}`
         once resumed, and a phantom operation is in progress.
         """
    test "a timed-out acquire is cancelled, so the lock is idle once it answers again" do
      test = self()
      :sys.suspend(Lock)
      on_exit(fn -> :sys.resume(Lock) end)

      assert Lock.with_lock(:backup, fn -> send(test, :body_ran) end) ==
               {:error, :lock_unreachable}

      refute_received :body_ran
      :sys.resume(Lock)

      assert Lock.current() == :idle
    end
  end

  describe "when the lock is unreachable" do
    setup do
      :ok = Supervisor.terminate_child(YmerNode.Supervisor, Lock)
      on_exit(fn -> Supervisor.restart_child(YmerNode.Supervisor, Lock) end)
      :ok
    end

    @tag :capture_log
    @tag doc: """
         The lock is a supervised sibling of the repo with its own restart window,
         and a call issued inside it EXITS rather than returning. Containing that
         exit here is what lets every caller read the lock without a catch of its
         own — `YmerNode.Notebook` reads it from a catch clause, which sits outside
         its own try, so an escaping exit there would reach the MCP framework's
         rescue, which sees exceptions only, and the caller would get nothing at
         all. A failure means the exit escaped again.
         """
    test "current/0 answers a third value instead of exiting" do
      assert Lock.current() == :unreachable
    end

    @tag :capture_log
    @tag doc: """
         The acquire exit, and the reason it gets a value of its own rather than
         being folded into `:operation_in_progress`: nothing is holding the lock,
         so telling the caller to wait for an operation to finish would be false.
         The body must not run — an operation that proceeded without the lock would
         race a concurrent one on the same files. A failure means the exit escaped,
         or the body ran unserialized.
         """
    test "with_lock/2 answers a distinct error instead of exiting, and does not run the body" do
      test = self()

      assert Lock.with_lock(:backup, fn -> send(test, :body_ran) end) ==
               {:error, :lock_unreachable}

      refute_received :body_ran
    end
  end

  describe "a lock that restarts under a running operation" do
    @tag :capture_log
    @tag doc: """
         The expensive half of the restart window: the release call sits in an
         `after`, and an exit there REPLACES what the body returned — so a restore
         that had already swapped the files came back to the caller as a raw
         process exit, taking the safety backup's id with it. Killing the lock from
         inside the body and returning at once is the measured way into that
         window. A failure means the release stopped containing its exit.
         """
    test "a release landing in the window does not replace the body's value" do
      assert Lock.with_lock(:backup, fn ->
               Process.exit(Process.whereis(Lock), :kill)
               :body_value
             end) == :body_value

      assert wait_for_lock(20) == :idle
    end
  end

  # The kill above is a real supervised restart, so the lock is briefly absent.
  defp wait_for_lock(0), do: flunk("the supervisor did not put the lock back")

  defp wait_for_lock(n) do
    case Lock.current() do
      :unreachable -> Process.sleep(10) && wait_for_lock(n - 1)
      state -> state
    end
  end

  # The :DOWN is asynchronous; poll a bounded number of times for the lock to free.
  defp acquire_within(0), do: flunk("lock was not released after the holder died")

  defp acquire_within(n) do
    case GenServer.call(Lock, {:acquire, :backup}) do
      :ok -> :ok
      {:error, :operation_in_progress} -> Process.sleep(10) && acquire_within(n - 1)
    end
  end
end
