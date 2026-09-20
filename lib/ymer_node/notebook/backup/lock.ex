defmodule YmerNode.Notebook.Backup.Lock do
  @moduledoc """
  Singleton mutex serializing `YmerNode.Notebook.Backup` operations — capture and
  restore.

  ## Why a mutex, and why the work runs in the caller

  A capture (`VACUUM INTO`) or a restore (stop repo, swap file, restart repo) is
  slow and must never run twice at once against the same files. This GenServer
  holds only the lock state; `with_lock/2` runs the actual work in the **calling**
  process while it holds the lock. That keeps a possibly multi-second operation
  out of this GenServer's mailbox, where it could trip a call timeout, and it
  means a second operation is **rejected** — `{:error, :operation_in_progress}` —
  rather than silently queued behind the first. A caller that asked to back up and
  got told "not now" can retry; one whose call sat in a queue for a minute cannot
  tell the difference between slow and stuck.

  The holder pid is monitored, so a caller that crashes mid-operation frees the
  lock on its `:DOWN` and cannot wedge the singleton.

  ## What a restart of this process costs

  Mutual exclusion does not survive a restart of this process under a running
  operation. The restarted lock's state is `%{holder: nil}`, so it answers
  `:idle` while a restore is still swapping files, and a second operation
  acquires. That is accepted rather than closed: the crash has no known trigger —
  `handle_call/3`'s bodies are constant-time and the process holds one small
  map — so machinery to re-register an in-flight holder would guard a path
  nothing has ever taken.

  What is not accepted is a caller losing a finished operation's answer to the
  same window, which is reachable from every restart OTP performs. Both of
  `with_lock/2`'s calls therefore contain their own exits, and `current/0`
  answers `:unreachable` rather than exiting into a caller that cannot catch it.

  The application's supervision tree starts this process after the repo, so
  the lock exists before anything can ask for it.
  """
  use GenServer

  require Logger

  # Every call here is a constant-time read or write of one small map, so a lock
  # that is alive and not answering within half a second is not slow, it is
  # wrong — and the caller is always inside an operation a person is waiting on.
  # `GenServer.call/2`'s default five seconds would hand that wait to them.
  @call_timeout 500

  # ─── Public API ─────────────────────────────────────────────────────

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Acquires the lock, runs `fun` in the caller process, and releases — returning
  whatever `fun` returns. If another operation already holds the lock, does not
  run `fun` and returns `{:error, :operation_in_progress}`. If the acquire does
  not come back — this process inside its own restart window, or alive and not
  answering within its call timeout — does not run `fun` either and returns
  `{:error, :lock_unreachable}`: a different fact from a held lock, and one the
  caller maps rather than catches. An acquire that timed out is cancelled behind
  itself, so a lock that answers late does not stay held by a caller that has
  already given up.

  The lock is released even if `fun` raises, and, as a backstop, if the caller
  process dies. A release that lands inside the restart window is logged and
  discarded: it never replaces what `fun` answered.
  """
  def with_lock(op, fun) when is_atom(op) and is_function(fun, 0) do
    case acquire(op) do
      :ok ->
        try do
          fun.()
        after
          release()
        end

      {:error, _reason} = err ->
        err
    end
  end

  @doc """
  Returns `:idle`, `{:busy, op}`, or `:unreachable` — the current lock state.

  `:unreachable` is this module's own word for "the call did not come back" —
  the same two exits `with_lock/2` names, contained here, logged, and answered
  as a third value, so no caller has to catch an exit to read the lock. The
  `:noproc` of the restart window answers at once; against a lock that is alive
  and not answering, this read costs the caller the call timeout before it
  answers.

  For tests, and for `YmerNode.Notebook`, which reads it to tell a restore's
  window — the one stopped state that closes on its own — from every other one;
  see its moduledoc. A caller-facing answer turns on the exact `:idle` /
  `{:busy, op}` / `:unreachable` split, and on the held `op` inside the second, so
  none of them is free to drift.
  """
  def current do
    GenServer.call(__MODULE__, :current, @call_timeout)
  catch
    kind, reason ->
      Logger.warning("notebook lock: state unreadable: #{inspect(kind)} #{inspect(reason)}")
      :unreachable
  end

  # ─── Callbacks ──────────────────────────────────────────────────────

  @impl true
  def init(:ok), do: {:ok, %{holder: nil}}

  @impl true
  def handle_call({:acquire, op}, {pid, _tag}, %{holder: nil} = state) do
    ref = Process.monitor(pid)
    {:reply, :ok, %{state | holder: {pid, ref, op}}}
  end

  def handle_call({:acquire, _op}, _from, state),
    do: {:reply, {:error, :operation_in_progress}, state}

  def handle_call(:release, {pid, _tag}, %{holder: {pid, ref, _op}} = state),
    do: {:reply, :ok, freed(ref, state)}

  # Release by a non-holder, or when already idle, is a no-op — it keeps the
  # `after` clause in with_lock/2 total even on odd interleavings.
  def handle_call(:release, _from, state), do: {:reply, :ok, state}

  def handle_call(:current, _from, %{holder: nil} = state), do: {:reply, :idle, state}

  def handle_call(:current, _from, %{holder: {_pid, _ref, op}} = state),
    do: {:reply, {:busy, op}, state}

  # The cancel a timed-out acquire sends behind itself. Messages from one process
  # to another arrive in order, so this can only be processed AFTER the acquire it
  # follows: an acquire this process granted late is freed by the very next
  # message from the same caller, and one it never saw — the process restarted in
  # between, mailbox and all — meets the same no-op a non-holder's release does.
  # A cast rather than a call because the caller has already given up waiting on
  # this process and must not be made to wait on it a second time.
  @impl true
  def handle_cast({:release, pid}, %{holder: {pid, ref, _op}} = state),
    do: {:noreply, freed(ref, state)}

  def handle_cast({:release, _pid}, state), do: {:noreply, state}

  # `ref` is the load-bearing repeated binding: the :DOWN frees the lock only when
  # its monitor ref equals the holder's. The pids are unused, and necessarily
  # equal when the refs match, so they take distinct underscore names — repeating
  # `_pid` would add a spurious equality constraint and a compiler warning.
  @impl true
  def handle_info(
        {:DOWN, ref, :process, _down_pid, _reason},
        %{holder: {_pid, ref, _op}} = state
      ),
      do: {:noreply, %{state | holder: nil}}

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  # ─── Private ────────────────────────────────────────────────────────

  # The two calls `with_lock/2` makes, each containing its own exit. Two exits are
  # reachable: `:noproc`, from the restart window OTP opens on every supervised
  # restart, measured in microseconds; and `:timeout`, from a process that is
  # alive and not answering. The second is the dangerous one — the request is
  # still in this process's mailbox and will be granted when it answers again, to
  # a caller that has stopped waiting — so it is cancelled behind itself: the cast
  # queues after the acquire and frees whatever that acquire took.
  defp acquire(op) do
    GenServer.call(__MODULE__, {:acquire, op}, @call_timeout)
  catch
    :exit, {:timeout, _call} ->
      Logger.warning("notebook lock: acquire timed out; cancelling it behind itself")
      GenServer.cast(__MODULE__, {:release, self()})
      {:error, :lock_unreachable}

    kind, reason ->
      Logger.warning("notebook lock: could not acquire: #{inspect(kind)} #{inspect(reason)}")
      {:error, :lock_unreachable}
  end

  # An exit here must not become the caller's answer: the release runs in an
  # `after`, where a raise replaces the body's return value — which is how a
  # restore that had already swapped the files came back as a raw process exit.
  # A restarted lock holds no record of this operation anyway, so a release that
  # cannot land has nothing left to free.
  defp release do
    GenServer.call(__MODULE__, :release, @call_timeout)
  catch
    kind, reason ->
      Logger.warning("notebook lock: release did not land: #{inspect(kind)} #{inspect(reason)}")
      :ok
  end

  # The one way the holder is let go, shared by the holder's own release and the
  # cancel a timed-out acquire sends: drop the monitor with its `:DOWN` flushed, so
  # a late `:DOWN` for a holder that has already been freed cannot arrive later.
  defp freed(ref, state) do
    Process.demonitor(ref, [:flush])
    %{state | holder: nil}
  end
end
