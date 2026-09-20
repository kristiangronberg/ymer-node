defmodule YmerNode.Notebook.RepoTest do
  @moduledoc """
  Stopping and restarting the repo through `YmerNode.Supervisor` is something the
  sandbox owner `YmerNode.NotebookCase` starts cannot survive, so this module uses
  a plain `ExUnit.Case`, is `async: false`, and puts the repo back before the test
  ends.
  """
  use ExUnit.Case, async: false

  alias DBConnection.ConnectionError
  alias Ecto.Adapters.SQL.Sandbox
  alias YmerNode.Notebook.Repo

  describe "running?/0" do
    @tag doc: """
         The liveness primitive every down-notebook answer rests on. It reads
         process state, never the text of Ecto's lookup failure: that message
         belongs to a dependency, and a check that matched it would keep passing
         until the wording changed upstream and then report a stopped notebook as
         running. A failure here means the repo is no longer registered under the
         name the supervisor starts it with.
         """
    test "follows the repo's supervised state" do
      assert Repo.running?()

      :ok = Supervisor.terminate_child(YmerNode.Supervisor, Repo)

      on_exit(fn ->
        Supervisor.restart_child(YmerNode.Supervisor, Repo)
        Sandbox.mode(Repo, :manual)
      end)

      refute Repo.running?()
    end

    @tag doc: """
         The window a name-only read admits: a named repo is registered before
         its start finishes, and Ecto records the metadata every query resolves
         only after the pool has started. The test process takes the name itself, which
         is exactly that state — registered, no metadata — and holds it for the
         whole read. A failure here means the read fell back to registration, and
         a call landing in a supervised restart crashes with a raw registry
         `ArgumentError` again instead of being waited for.
         """
    test "is false while the name is registered and Ecto has not finished starting the repo" do
      :ok = Supervisor.terminate_child(YmerNode.Supervisor, Repo)

      on_exit(fn ->
        Supervisor.restart_child(YmerNode.Supervisor, Repo)
        Sandbox.mode(Repo, :manual)
      end)

      Process.register(self(), Repo)
      refute Repo.running?()
      Process.unregister(Repo)
    end
  end

  describe "await_running/0" do
    @tag :capture_log
    @tag doc: """
         The wait that turns a supervised restart into a served call. The repo is
         handed back from another process 10 ms in, inside the budget, so the
         wait must answer true and the restart must be over when it does. A
         failure that looks like a timing flake is worth reading as one before
         the wait is blamed; a failure that answers false at once means the wait
         stopped polling.
         """
    test "answers true once a supervised restart hands the repo back" do
      test = self()
      :ok = Supervisor.terminate_child(YmerNode.Supervisor, Repo)

      on_exit(fn ->
        Supervisor.restart_child(YmerNode.Supervisor, Repo)
        Sandbox.mode(Repo, :manual)
      end)

      spawn(fn ->
        Process.sleep(10)
        Supervisor.restart_child(YmerNode.Supervisor, Repo)
        send(test, :repo_back)
      end)

      assert Repo.await_running()
      assert_receive :repo_back
    end

    @tag doc: """
         The bound. A repo that stays down is answered false after the budget
         and not before it — the lower bound is what keeps a genuine restart
         inside the wait, the upper bound is what keeps the wait from ever
         absorbing the pool's reconnect backoff. A failure on the lower bound
         means the wait returned early; on the upper, that a poll started
         blocking.
         """
    test "answers false when the repo stays down for the whole budget" do
      :ok = Supervisor.terminate_child(YmerNode.Supervisor, Repo)

      on_exit(fn ->
        Supervisor.restart_child(YmerNode.Supervisor, Repo)
        Sandbox.mode(Repo, :manual)
      end)

      started = System.monotonic_time(:millisecond)
      refute Repo.await_running()
      elapsed = System.monotonic_time(:millisecond) - started

      assert elapsed >= 50
      assert elapsed < 500
    end
  end

  describe "journal_mode/0" do
    @tag doc: """
         The restore switches a copy to whatever this answers, by interpolating
         the atom into a `PRAGMA`. The bound is the whole point: an unknown value
         must raise here rather than reach SQL, and the default must be the
         adapter's own so a repo with no `:journal_mode` configured reads the mode
         its pool actually runs in. A failure on the raise means an unbounded
         value can reach a `PRAGMA`; on the default, that a restore would switch a
         copy to a mode the pool does not use.
         """
    test "reads the configured mode, defaults to :wal, and refuses a value outside SQLite's modes" do
      prev = Application.get_env(:ymer_node, Repo)
      on_exit(fn -> Application.put_env(:ymer_node, Repo, prev) end)

      assert Repo.journal_mode() == :wal

      Application.put_env(:ymer_node, Repo, Keyword.put(prev, :journal_mode, :delete))
      assert Repo.journal_mode() == :delete

      Application.put_env(:ymer_node, Repo, Keyword.delete(prev, :journal_mode))
      assert Repo.journal_mode() == :wal

      Application.put_env(:ymer_node, Repo, Keyword.put(prev, :journal_mode, :bogus))
      assert_raise ArgumentError, fn -> Repo.journal_mode() end
    end
  end

  describe "not_serving?/1" do
    @tag doc: """
         The other half of the down-notebook answer, and the reason it is safe to
         read: it matches the exception's documented type and its documented
         `reason` field, never the message text. `:queue_timeout` is set only where
         the pool drops a request from its queue, before any connection is handed
         out, so a client that timed out holding a connection it did get cannot
         wear it. A failure here means a dependency renamed the struct or the atom
         — which is exactly what this test exists to make loud, since the
         classification would otherwise go quiet and report a store the node cannot
         open as a serving one.
         """
    test "recognises the pool's own report in all three shapes it arrives in" do
      dropped = %ConnectionError{reason: :queue_timeout, message: "dropped from queue"}

      assert Repo.not_serving?(dropped)
      assert Repo.not_serving?({:error, dropped})
      assert Repo.not_serving?({:badmatch, {:error, dropped}})
    end

    @tag doc: """
         The over-matching this read must not do. A `ConnectionError` for a
         connection the pool DID provide — the client timeout on a slow
         statement — carries `reason: :error`, which is the struct's default and
         says nothing; classifying on it would report a busy notebook as one whose
         store cannot be opened. A failure here means the match widened from the
         atom to the struct.
         """
    test "is false for a served fault, a stopped repo, and every other reason" do
      refute Repo.not_serving?(%ConnectionError{reason: :error, message: "checked out too long"})
      refute Repo.not_serving?(%Exqlite.Error{message: "no such table: t"})
      refute Repo.not_serving?(%RuntimeError{message: "could not lookup Ecto repo"})
      refute Repo.not_serving?({:error, :not_read_only})
      refute Repo.not_serving?(:idle)
    end
  end
end
