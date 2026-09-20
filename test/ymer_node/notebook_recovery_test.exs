defmodule YmerNode.NotebookRecoveryTest do
  @moduledoc """
  What the notebook answers while its repo is stopped or cannot open its store,
  what its guard does with a fault while the repo is serving, and what a restore
  answers when its swap fails.

  These cases stop and restart the repo through `YmerNode.Supervisor`, which the
  sandbox owner `YmerNode.NotebookCase` starts cannot survive — so they sit in one
  module on a plain `ExUnit.Case`, `async: false`, rather than beside the other
  tests for the modules they exercise. Every case that stops the repo puts it back
  before it ends; leave that out and every later test in the run finds no notebook.

  `stop_serving!/0` reaches the second state by restarting the repo onto a file
  SQLite cannot read, which leaves it registered with a pool that cannot connect.
  It also shortens the pool's queue settings for the duration, which the
  assertions do not depend on — the classification keys on the pool's `reason`
  atom, never on how long the pool waited — and without which every answer here
  costs four to six seconds.

  The backups directory is pointed at a per-test tmp dir and `rm_rf`'d on exit, the
  same arrangement `YmerNode.Notebook.BackupTest` uses.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias YmerNode.Mcp.Tools.Notebook.Actions
  alias YmerNode.Notebook
  alias YmerNode.Notebook.Backup
  alias YmerNode.Notebook.Backup.Lock
  alias YmerNode.Notebook.Repo
  alias YmerNode.Notebook.VecLoadCheck

  setup do
    tmp = Path.join(System.tmp_dir!(), "recovery_test_#{System.unique_integer([:positive])}")
    prev = Application.get_env(:ymer_node, Backup)
    Application.put_env(:ymer_node, Backup, directory: tmp, retain: 5)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:ymer_node, Backup, prev),
        else: Application.delete_env(:ymer_node, Backup)

      File.rm_rf!(tmp)
    end)

    %{tmp: tmp}
  end

  # The sandbox mode is re-asserted on the restarted pool: without it the next
  # case checks out a connection from a pool that is no longer in manual mode.
  defp stop_notebook! do
    :ok = Supervisor.terminate_child(YmerNode.Supervisor, Repo)

    on_exit(fn ->
      Supervisor.restart_child(YmerNode.Supervisor, Repo)
      Sandbox.mode(Repo, :manual)
    end)
  end

  # Points the repo at a file SQLite cannot read and restarts it, so the repo is
  # REGISTERED and its pool cannot connect — the state a bad swap used to leave
  # behind. The queue settings are this helper's own, never the repo's
  # configuration; the module doc says why they are safe to shorten.
  defp stop_serving! do
    prev = Application.get_env(:ymer_node, Repo)
    bad = Path.join(System.tmp_dir!(), "not_serving_#{System.unique_integer([:positive])}.db")
    File.write!(bad, :crypto.strong_rand_bytes(4096))

    on_exit(fn ->
      Application.put_env(:ymer_node, Repo, prev)
      Supervisor.terminate_child(YmerNode.Supervisor, Repo)
      Supervisor.restart_child(YmerNode.Supervisor, Repo)
      Sandbox.mode(Repo, :manual)
      File.rm(bad)
    end)

    :ok = Supervisor.terminate_child(YmerNode.Supervisor, Repo)

    Application.put_env(
      :ymer_node,
      Repo,
      Keyword.merge(prev, database: bad, queue_target: 10, queue_interval: 50)
    )

    {:ok, _pid} = Supervisor.restart_child(YmerNode.Supervisor, Repo)
    :ok
  end

  # Stops the repo and hands it back from another process after `delay` ms, which
  # is inside the guard's bounded wait. The order is what makes the case
  # deterministic rather than a race: the caller's own failure lands within
  # microseconds of the terminate, so the guard always classifies a stopped repo
  # first, and only then finds it back.
  #
  # The repair belongs in `on_exit` here for the same reason it does in every
  # other helper in this file: an `assert_receive` that times out, or a raise from
  # the code under test, ends the case before any inline repair would run, and the
  # sandbox would stay out of `:manual` for every later case in the run. The
  # spawned restart still runs — it is independent of the test process — so the
  # `on_exit` restart usually finds the repo already up and answers
  # `{:error, :running}`, which changes nothing.
  defp restart_after(delay) do
    test = self()

    on_exit(fn ->
      Supervisor.restart_child(YmerNode.Supervisor, Repo)
      Sandbox.mode(Repo, :manual)
    end)

    :ok = Supervisor.terminate_child(YmerNode.Supervisor, Repo)

    spawn(fn ->
      Process.sleep(delay)
      Supervisor.restart_child(YmerNode.Supervisor, Repo)
      send(test, :repo_back)
    end)
  end

  describe "with_notebook/2 when the repo is up at the call" do
    @tag doc: """
         The guard's catch, which the cases below never reach: they meet a repo
         that is already down, so the pre-check answers and the body never runs.
         This is the other half — a body that raises while the repo is up. It must
         come back untouched, because the guard's whole licence to catch is that it
         re-checks liveness rather than reading the exception: swallow a genuine
         fault here and a broken statement becomes "the notebook is down, ask the
         user to restart", which is a lie the caller acts on.
         """
    test "re-raises a fault of its own, unchanged" do
      assert_raise RuntimeError, "boom", fn ->
        Notebook.with_notebook(:read, fn -> raise "boom" end)
      end
    end

    @tag :capture_log
    @tag doc: """
         The race the catch exists for: the repo was up at the check and gone by
         the query. The body stops it and then queries, which is the raise the real
         race produces, and the answer must be the down answer rather than the
         exception. A failure here means the catch stopped re-checking — either it
         classifies everything (and the case above turns into a lie) or it
         re-raises everything (and this window ships a raw Ecto message).
         """
    test "classifies a raise as the down answer when the repo went down mid-call" do
      outcome =
        Notebook.with_notebook(:read, fn ->
          stop_notebook!()
          Repo.query("SELECT 1")
        end)

      assert outcome == {:error, :notebook_down}
    end
  end

  describe "the SQL surface while the notebook is down" do
    setup do
      stop_notebook!()
      :ok
    end

    @tag doc: """
         All four actions reach the repo, so all four have to answer rather than
         let Ecto's lookup failure through — an uncaught raise here reaches the MCP
         framework's own rescue, which ships the exception message to the caller as
         the tool's error. A failure means one action lost its guard.
         """
    test "every action answers notebook_down while nothing holds the lock" do
      assert Notebook.execute("CREATE TABLE t (id INTEGER PRIMARY KEY)") ==
               {:error, :notebook_down}

      assert Notebook.query("SELECT 1") == {:error, :notebook_down}
      assert Notebook.tables() == {:error, :notebook_down}
      assert Notebook.table_schema("t") == {:error, :notebook_down}
    end

    @tag :capture_log
    @tag doc: """
         The lock is a supervised sibling of the repo with its own restart window,
         and a `GenServer.call` to a name that is not registered exits rather than
         raises — an exit the guard's catch clause, which sits outside its own try,
         cannot contain. With the lock gone the read is answered as the stuck story
         instead of escaping as a raw exit. A failure here means the lock read
         raises through the guard again, and the MCP framework's rescue — which
         sees exceptions only — ships nothing to the caller.
         """
    test "answers notebook_down when the lock itself is unreachable" do
      :ok = Supervisor.terminate_child(YmerNode.Supervisor, Lock)
      on_exit(fn -> Supervisor.restart_child(YmerNode.Supervisor, Lock) end)

      assert Notebook.query("SELECT 1") == {:error, :notebook_down}
    end

    @tag doc: """
         Lock-busy wins over notebook-down, and the order is the whole point:
         during a legitimate restore's window the lock is held and the window will
         close, so "wait, then try again" is true. `:notebook_down` is reachable
         only with the lock idle — the stuck state, where trying again cannot help.
         A failure here means the two were classified the other way round, and one
         of the two answers is now a lie.
         """
    test "a held lock wins, so the answer is the one a second backup operation gets" do
      test = self()

      task =
        Task.async(fn ->
          Lock.with_lock(:restore, fn ->
            send(test, :holding)
            assert_receive :release
            :done
          end)
        end)

      assert_receive :holding
      assert Notebook.query("SELECT 1") == {:error, :operation_in_progress}
      send(task.pid, :release)
      assert :done = Task.await(task)
    end

    test "listing backups still works, since it never opens the database" do
      assert Backup.list() == []
    end

    @tag doc: """
         The tool layer shapes `tables/0`'s list, so it has to match the one answer
         that is not a list before it shapes anything. A failure here is a
         FunctionClauseError in the shaping, which the MCP framework ships to the
         caller as a raw exception message.
         """
    test "the tables action carries the answer through the tool boundary" do
      assert {:error, {:notebook_down, ctx}} = Actions.run(:tables, %{})
      assert ctx.action_verb == "list tables"
    end
  end

  describe "the SQL surface while the notebook is registered and not serving" do
    setup do
      stop_serving!()
      :ok
    end

    @tag :capture_log
    @tag doc: """
         The state a bad swap used to leave: the repo is REGISTERED, so the old
         classification called it up and re-raised, and the caller read a
         dependency's queue-timeout message as the tool's error. Every action has
         to answer instead — and the answer must not offer a retry, because the
         causes left once the restore checks its copy are permissions, disk faults
         and an edit under a running node, none of which a wait fixes. A failure
         here means the serving read stopped being consulted in the guard's catch.
         """
    test "every action answers notebook_not_serving" do
      assert Notebook.query("SELECT 1") == {:error, :notebook_not_serving}
      assert Notebook.execute("CREATE TABLE t (id INTEGER)") == {:error, :notebook_not_serving}
      assert Notebook.tables() == {:error, :notebook_not_serving}
      assert Notebook.table_schema("t") == {:error, :notebook_not_serving}
    end

    @tag :capture_log
    @tag doc: """
         The tool layer ships the atom's message and nothing else, so the answer
         has to reach it as an answer rather than as a raise — the framework's own
         rescue would otherwise put a dependency's queue-timeout prose in front of
         the caller. A failure here means the guard let the fault through again.
         """
    test "the answer carries through the tool boundary" do
      assert {:error, {:notebook_not_serving, ctx}} =
               Actions.run(:query, %{"sql" => "SELECT 1"})

      assert ctx.action_verb == "run query"
    end
  end

  describe "a call that lands in a supervised restart" do
    @tag :capture_log
    @tag doc: """
         A supervised restart of the repo is microseconds, so answering inside it
         would be a terminal instruction for a condition that has already resolved.
         At the pre-check nothing has run, so the guard simply waits and proceeds.
         The 10 ms hand-back against the guard's own budget is the timing this case
         rests on; a failure that looks like a timing flake is worth reading as one
         before the classification is blamed.
         """
    test "is served at the pre-check, not answered" do
      restart_after(10)

      outcome = Notebook.query("SELECT 1")

      assert_receive :repo_back
      assert {:ok, %{rows: [[1]]}} = outcome
    end

    @tag :capture_log
    @tag doc: """
         In the catch the body HAS run, and only a read may run again. A write's
         statement may already have committed before the failure, and the notebook
         is the one store the node cannot rebuild — so repeating it could apply it
         twice. The answer says the effect is unknown rather than offering a retry.
         A failure here means the guard stopped telling the two bodies apart, which
         is a data-integrity bug and not a wording one.
         """
    test "a write is told its effect is unknown" do
      outcome =
        Notebook.with_notebook(:write, fn ->
          restart_after(10)
          Repo.query("SELECT 1")
        end)

      assert_receive :repo_back
      assert outcome == {:error, :notebook_restarted}
    end

    @tag :capture_log
    @tag doc: """
         The read half of the same window: the body runs a second time, and the
         run counter is what proves it — the answer alone could come from a first
         run that somehow succeeded. A failure means reads stopped being retried
         and every caller now sees a restart it did not need to know about.
         """
    test "a read runs again" do
      Process.put(:runs, 0)

      outcome =
        Notebook.with_notebook(:read, fn ->
          runs = Process.get(:runs)
          Process.put(:runs, runs + 1)

          if runs == 0 do
            restart_after(10)
            Repo.query("SELECT 1")
          else
            :ran_again
          end
        end)

      assert_receive :repo_back
      assert outcome == :ran_again
      assert Process.get(:runs) == 2
    end
  end

  describe "the held op tells a restore's window from every other stopped state" do
    @tag :capture_log
    @tag doc: """
         Only a restore stops the repo, so only a `:restore` hold is the expected,
         self-closing window that "wait, then try again" is true for. A capture
         never stops the repo, so a `:backup` hold beside a stopped repo is a
         crash, and the bounded wait is what tells a self-healing crash from a
         stuck one. A failure here means the held op went back to being ignored,
         and a stuck notebook is hidden behind retry advice that cannot come true.
         """
    test "a backup hold beside a stopped repo is stuck, not a window" do
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
      stop_notebook!()

      assert Notebook.query("SELECT 1") == {:error, :notebook_down}

      send(task.pid, :release)
      assert :done = Task.await(task)
    end
  end

  describe "a repo whose start has not finished" do
    @tag :capture_log
    @tag doc: """
         The window between a supervised restart registering the repo's name and
         Ecto finishing the repo's start — microseconds to a few milliseconds,
         measured — in which a read of the name alone says the repo is back and
         the first query raises a raw `ArgumentError` out of Ecto's registry. The
         test process takes the name itself and holds it for the whole call, which
         is that state held open. The guard must wait it out and then answer,
         never run the body into it. A failure that is an `ArgumentError` means
         the liveness read fell back to registration; a served `{:ok, …}` means
         the test process somehow answered a query, which it cannot.
         """
    test "is waited for, never queried" do
      stop_notebook!()
      Process.register(self(), Repo)

      assert Notebook.query("SELECT 1") == {:error, :notebook_down}

      Process.unregister(Repo)
    end
  end

  describe "the backup operations while the notebook is not serving" do
    setup do
      stop_serving!()
      :ok
    end

    @tag :capture_log
    @tag doc: """
         A capture's `VACUUM INTO` meets the same failure every query does, and it
         meets it as a RETURNED tuple rather than a raise — which is why the
         serving read has to be consulted here too, and not only in the SQL guard.
         The answer it replaces told the caller to try again, on a state no number
         of retries changes.
         """
    test "a capture answers notebook_not_serving, not the retryable backup failure" do
      assert Backup.create() == {:error, :notebook_not_serving}
    end

    @tag :capture_log
    @tag doc: """
         A restore reaches the state through its safety capture, and the answer
         must arrive UNRELABELLED: `safety_backup/1` normalises every other capture
         failure to `:restore_failed`, whose message says to try again. Restoring
         anyway would overwrite a store the node cannot read, with no copy of
         it — data loss under the node's own hand on the one store the node exists
         to keep. A failure here means the pass-through clause went missing; the
         listing assertion is what proves nothing was captured before the refusal.
         """
    test "a restore refuses before it captures anything", %{tmp: tmp} do
      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, "notebook-2026-08-30-12-00-00.db"), "member")

      assert Backup.restore("2026-08-30-12-00-00") == {:error, :notebook_not_serving}
      assert Enum.map(Backup.list(), & &1.id) == ["2026-08-30-12-00-00"]
    end
  end

  describe "a capture that lands in a supervised restart" do
    @tag :capture_log
    @tag doc: """
         The same window the SQL guard waits out, met by a capture: the repo is
         handed back 10 ms in, inside the budget, and the capture must be served
         rather than answered with the terminal instruction to restart the node.
         The listing pins that a real member landed. A failure that answers
         `notebook_down` means the capture's liveness check stopped waiting; a
         failure that looks like a timing flake is worth reading as one first.
         """
    test "is served after the wait, not answered notebook_down" do
      restart_after(10)

      outcome = Backup.create()

      assert_receive :repo_back
      assert {:ok, %{id: id}} = outcome
      assert Enum.map(Backup.list(), & &1.id) == [id]
    end
  end

  describe "a recoverable restore failure at the tool boundary" do
    @tag :capture_log
    @tag doc: """
         The two answers a caller can act on come back as the framework's
         three-element error, which is what puts a hint on the error payload; the
         two-element form ships a bare string and the id would have to be read back
         out of the prose. The failure is forced at the copy, the swap's first step,
         by making the resolved source unreadable, so the live database is never
         touched — which is the answer whose hint is the retry, carrying the id to
         retry with. A failure here means the hint context stopped being built, and
         the hint's example now names nothing.
         """
    test "a swap that fails at the copy carries its retry hint out", %{tmp: tmp} do
      File.mkdir_p!(tmp)
      source = Path.join(tmp, "notebook-2026-08-30-12-00-00.db")
      File.write!(source, "not a real database")
      File.chmod!(source, 0o000)

      on_exit(fn ->
        Sandbox.mode(Repo, :manual)
        File.chmod(source, 0o600)
      end)

      outcome =
        Sandbox.unboxed_run(Repo, fn ->
          Actions.run(:restore, %{"id" => "2026-08-30-12-00-00"})
        end)

      assert {:error, {reason, ctx}, hint_context} = outcome
      assert {:restore_not_started, %{safety_backup: safety}} = reason
      assert is_binary(safety)
      assert hint_context == %{action: :restore, retry: "2026-08-30-12-00-00"}
      assert ctx.action_verb == "restore the notebook"
    end
  end

  describe "the boot refusal an operator reads" do
    @tag :capture_log
    @tag doc: """
         The boot refusal is the last answer the node gives about a notebook it
         cannot use, and once the not-serving answer has sent the user to the
         container log it is the line they read. Two different failures wear the
         same shape at this call, and naming the wrong one sends the operator
         hunting a vendored binary while their store sits unopenable. The path is
         named deliberately: this message is an operator's surface — a boot log
         line, never a caller's answer — so the path-opacity rule the caller-facing
         failures follow does not apply to it. A failure here means the two
         failures were folded back into one message.

         `init/1` is called directly because that is the whole of this child: it
         probes once and returns `:ignore`, leaving no process to drive from
         outside. The probe is disabled by config in this environment, so the case
         turns it on for its own duration.
         """
    test "names the store, not sqlite-vec, when the node cannot open the store" do
      stop_serving!()
      prev = Application.get_env(:ymer_node, VecLoadCheck)
      Application.put_env(:ymer_node, VecLoadCheck, enabled: true)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:ymer_node, VecLoadCheck, prev),
          else: Application.delete_env(:ymer_node, VecLoadCheck)
      end)

      assert_raise RuntimeError, ~r/cannot open its store/, fn -> VecLoadCheck.init([]) end
    end

    @tag doc: """
         The control the case above needs: on a serving notebook with vec0 loaded,
         the same call answers `:ignore` and the supervisor keeps no process. A
         failure here means the probe stopped succeeding on a build whose `vec0`
         loads, and the refusal case above proves nothing until this one passes.
         """
    test "answers :ignore on a serving notebook" do
      prev = Application.get_env(:ymer_node, VecLoadCheck)
      Application.put_env(:ymer_node, VecLoadCheck, enabled: true)

      on_exit(fn ->
        if prev,
          do: Application.put_env(:ymer_node, VecLoadCheck, prev),
          else: Application.delete_env(:ymer_node, VecLoadCheck)
      end)

      assert Sandbox.unboxed_run(Repo, fn -> VecLoadCheck.init([]) end) == :ignore
    end
  end
end
