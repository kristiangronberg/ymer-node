defmodule YmerNode.Notebook.BackupTest do
  @moduledoc """
  Tests for `YmerNode.Notebook.Backup` — capture, listing, retention and restore.

  Test-infrastructure caveats:

  - `VACUUM` cannot run inside a transaction and the repo is sandboxed
    (`:manual`) in tests, so every case that triggers a real VACUUM runs it via
    `Ecto.Adapters.SQL.Sandbox.unboxed_run/2` against the REAL test database and
    cleans up after itself — those writes are not rolled back. This module is
    `async: false` throughout.
  - Every case that calls `restore/1` or `with_repo_down/2` stops and restarts
    the shared repo through `YmerNode.Supervisor`. Such cases must not run
    concurrently with other notebook tests (none of which are async), and each
    re-asserts `Sandbox.mode(…, :manual)` afterwards so a restarted pool cannot
    poison later cases in the same run.
  - Per-test isolation: each test points `:directory` at a unique tmp dir and sets
    a small `:retain`, both restored and `rm_rf`'d on exit. Tests exercising
    pruning override `:retain` again inside the test.
  - The cases that only exercise id handling, listing and retention write plain
    files into the tmp dir rather than capturing real backups. That is deliberate:
    those paths never open a database, so a real VACUUM would only make them slow
    and flaky.
  - The path-opacity cases force a filesystem failure deterministically by
    pointing `:directory` *under* a regular file, so every `File` operation raises
    ENOTDIR carrying the path. They are `:capture_log`-tagged because the opacity
    boundary logs that path-bearing detail server-side by design.
  """
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Exqlite.Sqlite3
  alias YmerNode.Notebook.Backup
  alias YmerNode.Notebook.Backup.Lock
  alias YmerNode.Notebook.Repo

  @retain 5
  @id "2026-08-30-12-00-00"

  setup do
    tmp = Path.join(System.tmp_dir!(), "node_backup_test_#{System.unique_integer([:positive])}")
    prev = Application.get_env(:ymer_node, Backup)
    Application.put_env(:ymer_node, Backup, directory: tmp, retain: @retain)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:ymer_node, Backup, prev),
        else: Application.delete_env(:ymer_node, Backup)

      File.rm_rf!(tmp)
    end)

    %{tmp: tmp}
  end

  defp touch_backup(tmp, id, contents \\ "not a real database") do
    File.mkdir_p!(tmp)
    path = Path.join(tmp, "notebook-#{id}.db")
    File.write!(path, contents)
    path
  end

  # A real single-file SQLite database, which is what every member on disk is.
  # The pre-swap check opens the copy and switches it to the configured journal
  # mode — WAL in this suite's config — so a plain string is refused at that
  # statement; the cases that only exercise id handling, listing and retention
  # keep `touch_backup/3`, since those paths never open a database. A member is
  # a rollback-journal database, like everything `VACUUM INTO` writes: bytes 18
  # and 19 of the header — SQLite's journal-mode pair — read `<<1, 1>>` here,
  # and `<<2, 2>>` on a file switched to WAL.
  defp real_member(tmp, id) do
    File.mkdir_p!(tmp)
    path = Path.join(tmp, "notebook-#{id}.db")
    {:ok, db} = Sqlite3.open(path)
    :ok = Sqlite3.execute(db, "CREATE TABLE member_probe (note TEXT)")
    :ok = Sqlite3.execute(db, "INSERT INTO member_probe(note) VALUES ('restored bytes')")
    :ok = Sqlite3.close(db)
    path
  end

  # Reads the fixture's row back out of a backup. The swap switches the copy on
  # its way in, so the file that lands is deliberately NOT byte-identical to the
  # member it came from — the row is what proves the member's data crossed.
  # The statement is released before the close: a close over an unfinalised
  # statement leaves the handle half-open and the `-wal`/`-shm` beside the file,
  # which would fail every listing assertion that follows a read.
  defp member_note(path) do
    {:ok, db} = Sqlite3.open(path)
    {:ok, statement} = Sqlite3.prepare(db, "SELECT note FROM member_probe")
    {:ok, rows} = Sqlite3.fetch_all(db, statement)
    :ok = Sqlite3.release(db, statement)
    :ok = Sqlite3.close(db)
    rows
  end

  # A valid WAL file left where the restore's temp copy will be written, carrying
  # committed frames of ANOTHER database with the fixture's table name. It is what
  # a switch that never closed cleanly leaves behind, and what SQLite replays into
  # the next file to appear at that path if nothing clears it first: the WAL is
  # written while its own database is still open, then copied, then that database
  # is closed and removed, so the frames stay valid and nothing else refers to them.
  defp stale_wal_at(tmp, path) do
    other = Path.join(tmp, "other.db")
    {:ok, db} = Sqlite3.open(other)
    :ok = Sqlite3.execute(db, "PRAGMA journal_mode=wal")
    :ok = Sqlite3.execute(db, "CREATE TABLE member_probe (note TEXT)")
    :ok = Sqlite3.execute(db, "INSERT INTO member_probe(note) VALUES ('stale frames')")
    File.cp!(other <> "-wal", path <> "-wal")
    :ok = Sqlite3.close(db)
    File.rm!(other)
  end

  # Points :directory under a regular file, so every filesystem operation inside
  # the module raises ENOTDIR. Returns the unreadable directory for tests that
  # need to assert its absence from a caller-facing message.
  defp block_backups_dir(name) do
    blocker = Path.join(System.tmp_dir!(), "#{name}_#{System.unique_integer([:positive])}")
    File.write!(blocker, "x")
    bad_dir = Path.join(blocker, "backups")
    Application.put_env(:ymer_node, Backup, directory: bad_dir, retain: @retain)
    on_exit(fn -> File.rm_rf!(blocker) end)
    bad_dir
  end

  describe "directory/0 and retain/0" do
    test "read the configured values", %{tmp: tmp} do
      assert Backup.directory() == tmp
      assert Backup.retain() == @retain
    end
  end

  describe "resolve/1" do
    @tag doc: """
         The id arrives from a worker and is used to build a filename, so this is
         the traversal guard. A failure means a crafted id reached the filesystem —
         check the anchoring on the id pattern before touching the test.
         """
    test "rejects an id that is not a bare timestamp token" do
      assert Backup.resolve("../../etc/passwd") == {:error, :invalid_backup_id}
      assert Backup.resolve("/etc/passwd") == {:error, :invalid_backup_id}
      assert Backup.resolve("2026-08-30") == {:error, :invalid_backup_id}
      assert Backup.resolve("") == {:error, :invalid_backup_id}
      assert Backup.resolve(@id <> "\n") == {:error, :invalid_backup_id}
    end

    test "reports a well-formed id with no file as not found" do
      assert Backup.resolve(@id) == {:error, :backup_not_found}
    end

    test "returns the path of an existing backup", %{tmp: tmp} do
      path = touch_backup(tmp, @id)
      assert Backup.resolve(@id) == {:ok, path}
    end
  end

  describe "list/0" do
    test "returns an empty list when nothing has been captured" do
      assert Backup.list() == []
    end

    test "returns entries newest first with size and creation time", %{tmp: tmp} do
      touch_backup(tmp, "2026-08-30-10-00-00", "older")
      touch_backup(tmp, "2026-08-30-12-00-00", "newer contents")

      assert [newer, older] = Backup.list()
      assert newer.id == "2026-08-30-12-00-00"
      assert newer.created_at == "2026-08-30T12:00:00Z"
      assert newer.size_bytes == byte_size("newer contents")
      assert older.id == "2026-08-30-10-00-00"
    end

    @tag doc: """
         A failure means the member pattern loosened and unrelated files in the
         backups directory are being reported as backups.
         """
    test "ignores files that are not backup members", %{tmp: tmp} do
      touch_backup(tmp, @id)
      File.write!(Path.join(tmp, "notes.txt"), "hello")
      File.write!(Path.join(tmp, "notebook-nope.db"), "hello")

      assert [%{id: @id}] = Backup.list()
    end

    @tag :capture_log
    @tag doc: """
         Pins the failure channel for a member the process cannot stat: a real
         fault (not the vanished-member race) fails the listing loudly as
         `{:error, :backups_failed}` instead of silently shortening it. A
         failure here means `listed_entry/2`'s rescue widened past `:enoent`.
         """
    test "a member that cannot be stat'ed fails the listing rather than vanishing", %{tmp: tmp} do
      touch_backup(tmp, @id)
      on_exit(fn -> File.chmod!(tmp, 0o700) end)
      File.chmod!(tmp, 0o600)

      assert Backup.list() == {:error, :backups_failed}
    end
  end

  describe "allocate/2" do
    @tag doc: """
         VACUUM INTO refuses an existing target, so a reused id would fail the
         capture and send create/1 down its cleanup path — which removes the file
         at that id, destroying the pre-existing backup. A failure here is a data
         loss bug, not a naming nit.
         """
    test "advances one second past an id already on disk", %{tmp: tmp} do
      touch_backup(tmp, @id)
      {:ok, taken, _} = DateTime.from_iso8601("2026-08-30T12:00:00Z")

      assert Backup.allocate(taken, tmp) == "2026-08-30-12-00-01"
    end

    test "returns the formatted instant when nothing collides", %{tmp: tmp} do
      {:ok, free, _} = DateTime.from_iso8601("2026-08-30T12:00:00Z")
      File.mkdir_p!(tmp)

      assert Backup.allocate(free, tmp) == @id
    end
  end

  describe "prune_to_retain/1" do
    test "drops the oldest beyond the limit", %{tmp: tmp} do
      for minute <- 0..6, do: touch_backup(tmp, "2026-08-30-12-0#{minute}-00")
      assert length(Backup.list()) == 7

      Backup.prune_to_retain()

      ids = Enum.map(Backup.list(), & &1.id)
      assert length(ids) == @retain
      refute "2026-08-30-12-00-00" in ids
      assert "2026-08-30-12-06-00" in ids
    end

    @tag doc: """
         The restore path passes the id being restored as exempt. Without it, the
         safety capture can prune the very backup whose path was just resolved,
         and the swap then fails mid-restore with the repo already down.
         """
    test "never drops an exempt id, even when it is the oldest", %{tmp: tmp} do
      for minute <- 0..6, do: touch_backup(tmp, "2026-08-30-12-0#{minute}-00")

      Backup.prune_to_retain(["2026-08-30-12-00-00"])

      ids = Enum.map(Backup.list(), & &1.id)
      assert "2026-08-30-12-00-00" in ids
    end

    @tag :capture_log
    @tag doc: """
         Guards the regression where pruning turned a successful capture into an
         error. `list/0` answers an unreadable backups directory with
         `{:error, :backups_failed}` rather than raising, and pruning runs AFTER
         the capture, so a `prune_to_retain/1` that piped that tuple into
         `Enum.drop/2` raised `Protocol.UndefinedError` and create/1's rescue
         reported `:backup_failed` for a backup already safely on disk. A failure
         here means the tuple branch went missing, at `list/0`'s end or at
         `prune_to_retain/1`'s.
         """
    test "tolerates an unreadable backups directory instead of raising" do
      block_backups_dir("unreadable")

      assert Backup.list() == {:error, :backups_failed}
      assert Backup.prune_to_retain() == :ok
    end
  end

  describe "swap_into_place/3" do
    @tag doc: """
         The two header reads are SQLite's journal-mode pair, bytes 18 and 19:
         `<<2, 2>>` is WAL, `<<1, 1>>` the rollback journal every member is written
         in. The swap switches the COPY, so the file that lands and the member it
         came from are deliberately not byte-identical, and asserting equality
         between them would pin the opposite of what this feature does. A failure
         on the first read means the file that landed was never switched, so the
         restarted pool meets a rollback-journal store and races itself converting
         it; a failure on the second means the switch moved onto the source, which
         mutates a backup on disk.
         """
    test "replaces the target, clears stale WAL and SHM, and preserves the source", %{tmp: tmp} do
      src = real_member(tmp, @id)
      db = Path.join(tmp, "live.db")
      File.write!(db, "live bytes")
      File.write!(db <> "-wal", "stale wal")
      File.write!(db <> "-shm", "stale shm")

      assert :ok = Backup.swap_into_place(src, db, :wal)

      assert binary_part(File.read!(db), 18, 2) == <<2, 2>>
      assert binary_part(File.read!(src), 18, 2) == <<1, 1>>
      refute File.exists?(db <> "-wal")
      refute File.exists?(db <> "-shm")
      refute File.exists?(db <> ".restore-tmp")
      assert member_note(db) == [["restored bytes"]]
    end

    test "succeeds when no WAL or SHM is present", %{tmp: tmp} do
      src = real_member(tmp, @id)
      db = Path.join(tmp, "live.db")
      File.write!(db, "live bytes")

      assert :ok = Backup.swap_into_place(src, db, :wal)
      assert binary_part(File.read!(db), 18, 2) == <<2, 2>>
      assert member_note(db) == [["restored bytes"]]
    end

    @tag doc: """
         The check runs on the COPY and leaves nothing beside it: a clean close
         checkpoints and removes the `-wal`/`-shm` the switch created, so the
         rename moves one file and the store's directory gains no orphans. A
         failure here means the check moved onto the source member — which would
         mutate a backup on disk — or the handle stopped being closed, and either
         way the install grows files nothing owns.
         """
    test "leaves no artefacts beside the store or the source", %{tmp: tmp} do
      src = real_member(tmp, @id)
      db = Path.join(tmp, "live.db")
      File.write!(db, "live bytes")

      assert :ok = Backup.swap_into_place(src, db, :wal)

      assert Enum.sort(File.ls!(tmp)) == ["live.db", "notebook-#{@id}.db"]
    end

    @tag :capture_log
    @tag doc: """
         The refusal that keeps a backup the pool could never open out of the
         store altogether. Without it the bad file reached the live store, the
         restart answered `{:ok, …}`, every later query crashed, and the one
         instruction the caller had — restart the app — became a boot that never
         completes. It runs before the first removal, so the live database still
         holds its own bytes and its `-wal` is still beside it; that is what makes
         "nothing was overwritten" true rather than merely likely. The directory
         listing is the third assertion because a refusal writes a file too: the
         copy the check just rejected. `swap_into_place/3` removes it before
         answering, so a refused restore leaves the store's directory exactly as it
         found it. A failure on the first two means the check moved after a removal
         and the answer's promise is a lie; a failure on the third means a
         full-size copy of every rejected backup is accumulating beside the store.
         """
    test "refuses a backup that does not open as a database, touching nothing", %{tmp: tmp} do
      File.mkdir_p!(tmp)
      src = Path.join(tmp, "notebook-#{@id}.db")
      File.write!(src, "not a real database")
      db = Path.join(tmp, "live.db")
      File.write!(db, "live bytes")
      File.write!(db <> "-wal", "live wal")

      assert Backup.swap_into_place(src, db, :wal) == {:error, :backup_unreadable}

      assert File.read!(db) == "live bytes"
      assert File.read!(db <> "-wal") == "live wal"
      assert Enum.sort(File.ls!(tmp)) == ["live.db", "live.db-wal", "notebook-#{@id}.db"]
    end

    @tag doc: """
         Pins the swap's ordering, which nothing else in this suite sees: on a
         clean run the two orderings leave identical files behind. The live
         database still holding its own bytes after a failed WAL removal is what
         `swap_into_place/3`'s rm-before-rename provides. A failure means the
         rename now runs first, so a crash mid-swap can pair the new database with
         the old WAL — the corruption this feature exists to prevent. The source
         must be a real database or the pre-swap check refuses before the removal
         is ever reached, and this case stops pinning anything. The directory
         standing where the `-wal` file would be is deliberate: it is what makes
         `File.rm/1` return a real, non-`:enoent` error and reach the raise.
         `assert_raise` names the exception class alone because the errno differs
         across platforms.
         """
    test "raises before the rename when the stale WAL cannot be removed", %{tmp: tmp} do
      src = real_member(tmp, @id)
      db = Path.join(tmp, "live.db")
      File.write!(db, "live bytes")
      File.mkdir_p!(db <> "-wal")

      assert_raise File.Error, fn -> Backup.swap_into_place(src, db, :wal) end

      assert File.read!(db) == "live bytes"
      assert File.exists?(src)
    end

    @tag doc: """
         The switch targets the pool's configured mode, not WAL unconditionally.
         On a node configured for another journal mode every connection of the
         restarted pool would otherwise convert the file straight back, one at a
         time — the very "database is locked" race the switch exists to remove.
         `:delete` is the rollback journal, so the header pair must still read
         `<<1, 1>>` after the swap while the row proves the member's data crossed.
         A failure here means the `mode` argument is ignored and the mode
         hardcoded again; that the restore path hands this function the
         configured mode is pinned by the refused-journal-mode case under
         `restore/1`.
         """
    test "switches the copy to the configured journal mode, not to WAL unconditionally",
         %{tmp: tmp} do
      src = real_member(tmp, @id)
      db = Path.join(tmp, "live.db")
      File.write!(db, "live bytes")

      assert :ok = Backup.swap_into_place(src, db, :delete)
      assert binary_part(File.read!(db), 18, 2) == <<1, 1>>
      assert member_note(db) == [["restored bytes"]]
    end

    @tag doc: """
         Guards the corruption a leftover at the temp path causes: a valid WAL a
         previous restore's switch left beside its copy is replayed by SQLite into
         the NEXT file to appear at that path — the very open that is meant to
         check the copy — so the member lands paired with another database's
         frames. Measured before the clear existed: the row read back was the
         stale WAL's, not the member's. A failure on the row means the temp path
         stopped being cleared before the copy; a failure on the listing means the
         leftover was replayed and then left behind as well.
         """
    test "clears a stale WAL left at the temp path before the copy, so it is never replayed",
         %{tmp: tmp} do
      src = real_member(tmp, @id)
      db = Path.join(tmp, "live.db")
      File.write!(db, "live bytes")
      stale_wal_at(tmp, db <> ".restore-tmp")

      assert :ok = Backup.swap_into_place(src, db, :wal)

      assert Enum.sort(File.ls!(tmp)) == ["live.db", "notebook-#{@id}.db"]
      assert member_note(db) == [["restored bytes"]]
    end

    @tag :capture_log
    @tag doc: """
         The phase split. A leftover the node cannot clear — a directory standing
         where the temp copy's `-wal` would be, which `File.rm/1` refuses with a
         real error — stops the restore before a byte is written, and the answer
         must say exactly that: nothing started, so a retry is honest and the
         cause is in the log. Before the split this case answered
         `:backup_unreadable`, telling the caller to abandon a backup that opens
         fine; a raise from the same phase was reported as an overwrite. A failure
         here means the first phase's raises stopped being answered as nothing
         having started.
         """
    test "answers not started, not unreadable, when a leftover at the temp path cannot be cleared",
         %{tmp: tmp} do
      src = real_member(tmp, @id)
      db = Path.join(tmp, "live.db")
      File.write!(db, "live bytes")
      File.mkdir_p!(db <> ".restore-tmp-wal")

      assert Backup.swap_into_place(src, db, :wal) == {:error, :swap_not_started}

      assert File.read!(db) == "live bytes"
      assert File.exists?(src)
    end
  end

  describe "with_repo_down/2" do
    @describetag :notebook_db

    @tag doc: """
         The restart happens in `run_with_repo_down/2`'s try/catch, whatever `fun`
         returned or raised, so a raising swap still brings the repo back. A failure
         leaves the repo down for every later test in the run — check
         `run_with_repo_down/2` before assuming the assertion is wrong.
         """
    test "restarts the repo even when the function raises" do
      assert_raise RuntimeError, "boom", fn ->
        Backup.with_repo_down(Repo, fn -> raise "boom" end)
      end

      # Mid-test, not `on_exit`: the restart above replaced the pool, and the
      # `unboxed_run` below checks out from the new one inside this test.
      Sandbox.mode(Repo, :manual)

      outcome =
        Sandbox.unboxed_run(Repo, fn ->
          {:ok, _} = Repo.query("SELECT 1")
          :queried
        end)

      assert outcome == :queried
    end

    @tag :capture_log
    @tag doc: """
         The body's answer and the notebook's serving state are two facts and must
         stay two. A failure here means they were collapsed again — which is how a
         restore that had already landed came back as a plain failure, taking the
         safety backup's id with it.
         """
    test "returns the body's value and the notebook's serving state separately" do
      on_exit(fn -> Sandbox.mode(Repo, :manual) end)

      assert Backup.with_repo_down(Repo, fn -> :body_value end) == {:done, :body_value, :serving}
    end

    @tag :capture_log
    @tag doc: """
         The state the serve probe exists to find, driven end to end: the body
         points the repo at a file SQLite cannot read, so the restart registers a
         pool whose connections then fail asynchronously — which is why
         `restart_child/2`'s own `{:ok, pid}` was never an answer about service.
         The body's only job is the configuration change; `with_repo_down/2` has
         already stopped the repo and is the one that restarts it onto the new
         setting. The queue settings are the test's own and are restored on exit;
         without them the probe waits the pool's four-second default. A failure
         here means a repo that cannot serve is being read as `:serving` again,
         which puts a restore's `{:ok, …}` in front of a caller whose next query
         crashes.
         """
    test "reports the notebook not serving after a restart onto a store it cannot open" do
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

      outcome =
        Backup.with_repo_down(Repo, fn ->
          Application.put_env(
            :ymer_node,
            Repo,
            Keyword.merge(prev, database: bad, queue_target: 10, queue_interval: 50)
          )

          :body_value
        end)

      assert outcome == {:done, :body_value, :not_serving}
    end

    @tag :capture_log
    @tag doc: """
         Deleting the child spec from inside the down window is the only
         deterministic way to make the restart fail: `Supervisor.restart_child/2`
         answers `{:ok, pid}` even for a repo pointed at a database it cannot open,
         because the pool's connections fail later and asynchronously — which is
         exactly why registration alone was never enough, and why a statement runs
         after it now. Putting the spec back belongs in `on_exit` and nowhere else
         — a raise before an inline repair would leave every later test in the run
         without a notebook.
         """
    test "reports the notebook down after a failed restart, keeping the body's value" do
      on_exit(fn ->
        Supervisor.start_child(YmerNode.Supervisor, Repo)
        Sandbox.mode(Repo, :manual)
      end)

      outcome =
        Backup.with_repo_down(Repo, fn ->
          :ok = Supervisor.delete_child(YmerNode.Supervisor, Repo)
          :body_value
        end)

      assert outcome == {:done, :body_value, :down}
    end

    @tag :capture_log
    @tag doc: """
         `Supervisor.terminate_child/2`'s only error is `:not_found`, so an absent
         child spec is the whole of this path. The body must not run: nothing is
         touched, which is what makes retrying the restore legitimate rather than
         destructive. The repair belongs in `on_exit` for the reason above.
         """
    test "answers not_started, without running the body, when the repo cannot be stopped" do
      :ok = Supervisor.terminate_child(YmerNode.Supervisor, Repo)
      :ok = Supervisor.delete_child(YmerNode.Supervisor, Repo)

      on_exit(fn ->
        Supervisor.start_child(YmerNode.Supervisor, Repo)
        Sandbox.mode(Repo, :manual)
      end)

      outcome = Backup.with_repo_down(Repo, fn -> send(self(), :body_ran) end)

      assert outcome == {:not_started, :not_found}
      refute_received :body_ran
    end
  end

  describe "restore_outcome/3" do
    @tag doc: """
         Every answer a restore can end on, and the ids each one carries. The
         restart's own answer is registration, not service: `restart_child/2`
         answers `{:ok, pid}` for a repo pointed at a store it cannot open, so a
         restore that landed on such a file used to answer `{:ok, …}` and the next
         query crashed. The three serving values are three different observers — a
         process that is gone, a file the operator has to look at, and a notebook
         that works — and folding two of them together loses the one that says
         which. The failure answers are separated by DISK STATE first: a copy that
         was refused or that failed overwrote nothing, anything later did. And
         when nothing was overwritten, the notebook's state after the restart
         decides the answer, because "retry" and "choose another backup" are
         instructions that cannot come true for a notebook that did not come back
         — the bare down and not-serving answers are the ones whose next action a
         caller can take. A failure here means an answer stopped naming the safety
         backup where the store may have changed, or that a notebook that did not
         come back is being told to retry.
         """
    test "names the safety backup on every answer that could have changed the store" do
      safety = "2026-08-30-11-00-00"
      ids = %{restored: @id, safety_backup: safety}

      assert Backup.restore_outcome({:done, :ok, :serving}, @id, safety) == {:ok, ids}

      assert Backup.restore_outcome({:done, :ok, :not_serving}, @id, safety) ==
               {:error, {:restored_notebook_not_serving, ids}}

      assert Backup.restore_outcome({:done, :ok, :down}, @id, safety) ==
               {:error, {:restored_notebook_down, ids}}

      assert Backup.restore_outcome({:done, {:error, :backup_unreadable}, :serving}, @id, safety) ==
               {:error, {:backup_unreadable, %{safety_backup: safety}}}

      assert Backup.restore_outcome({:done, {:error, :swap_not_started}, :serving}, @id, safety) ==
               {:error, {:restore_not_started, %{safety_backup: safety}}}

      for untouched <- [:backup_unreadable, :swap_not_started] do
        assert Backup.restore_outcome({:done, {:error, untouched}, :down}, @id, safety) ==
                 {:error, :notebook_down}

        assert Backup.restore_outcome({:done, {:error, untouched}, :not_serving}, @id, safety) ==
                 {:error, :notebook_not_serving}
      end

      for serving <- [:serving, :not_serving, :down] do
        assert Backup.restore_outcome({:done, {:error, :swap_failed}, serving}, @id, safety) ==
                 {:error, {:restore_incomplete, %{safety_backup: safety}}}
      end

      assert Backup.restore_outcome({:not_started, :not_found}, @id, safety) ==
               {:error, {:restore_not_started, %{safety_backup: safety}}}
    end
  end

  describe "create/1 and restore/1 route through the Lock" do
    @tag doc: """
         Pins BOTH entry points, and must keep doing so: create/1 and restore/1
         take the lock separately, neither's success shape depends on its
         `with_lock` wrapper, and this is the only case that sees either one — do
         not thin it to one call. A failure means one of them stopped routing
         through the lock, which lets a restore's swap race a capture's VACUUM on
         the same files; check both wrappers before touching the test.
         """
    test "both reject while another op holds the lock" do
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
      # The id is irrelevant: both calls take the lock before they resolve it.
      assert Backup.create() == {:error, :operation_in_progress}
      assert Backup.restore(@id) == {:error, :operation_in_progress}
      send(task.pid, :release)
      assert :done = Task.await(task)
      assert Lock.current() == :idle
    end

    @tag :capture_log
    @tag doc: """
         A lock that cannot be reached is not a lock that is held: nothing is
         running, so `:operation_in_progress` would be false, and the acquire
         exited rather than returning, so letting it through would ship a raw
         process exit. Both entry points wait out the restart window first — a
         supervised restart is microseconds — and only a lock that is still gone
         afterwards means its supervisor is gone, which is the one case where "ask
         the user to restart the app" is the true instruction. A failure here means
         one of the two stopped mapping the lock's answer.
         """
    test "both answer notebook_down when the lock stays unreachable" do
      :ok = Supervisor.terminate_child(YmerNode.Supervisor, Lock)
      on_exit(fn -> Supervisor.restart_child(YmerNode.Supervisor, Lock) end)

      assert Backup.create() == {:error, :notebook_down}
      assert Backup.restore(@id) == {:error, :notebook_down}
    end

    @tag :capture_log
    @tag doc: """
         The bound on the wait, against the one lock state where a poll blocks: a
         lock that is alive and not answering costs the Lock's call timeout per
         read, and a wait that counted only its own sleeps polled that timeout ten
         times over — measured at 5.5 s where the budget says 50 ms. The bound
         here is loose on purpose: it has to hold on a slow machine and still tell
         one blocked poll from ten. The `:idle` at the end pins the other half —
         the timed-out acquire was cancelled, so the lock is not left held by a
         caller that gave up. A failure on the time means the wait is counting
         sleeps again; on the state, that the cancel stopped landing.
         """
    test "a lock that is alive and not answering costs one call timeout, not ten" do
      :sys.suspend(Lock)
      on_exit(fn -> :sys.resume(Lock) end)

      started = System.monotonic_time(:millisecond)
      assert Backup.create() == {:error, :notebook_down}
      elapsed = System.monotonic_time(:millisecond) - started

      :sys.resume(Lock)

      assert elapsed < 2_500
      assert Lock.current() == :idle
    end
  end

  describe "path opacity on a forced filesystem failure" do
    @tag :capture_log
    @tag doc: """
         Runtime no-leak on the ERROR path — the boundary the module doc promises.
         `File` bang operations embed absolute paths, and an uncaught raise would
         reach the MCP framework's own top-level rescue, which ships
         `Exception.message/1` verbatim to the caller: a filesystem path in a
         worker's context. Both entry points are named because they rescue
         separately. A failure here means one of those rescues was dropped.
         """
    test "create/1 and restore/1 return path-free atoms rather than raising" do
      block_backups_dir("opaque")

      assert Backup.create() == {:error, :backup_failed}
      assert Backup.restore(@id) == {:error, :restore_failed}
    end
  end

  describe "create/1 (integration — real VACUUM)" do
    @describetag :notebook_db

    @tag doc: """
         The captured file must still carry the vec0 virtual table's data —
         checked by querying the copy, which is the failure a "file exists"
         assertion would miss entirely.
         """
    test "captures a file whose vector table survives the copy", %{tmp: tmp} do
      on_exit(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.query!("DROP TABLE IF EXISTS vec_backup_probe")
        end)
      end)

      entry =
        Sandbox.unboxed_run(Repo, fn ->
          Repo.query!("DROP TABLE IF EXISTS vec_backup_probe")

          Repo.query!(
            "CREATE VIRTUAL TABLE vec_backup_probe USING vec0(id INTEGER PRIMARY KEY, v float[3])"
          )

          Repo.query!("INSERT INTO vec_backup_probe(id, v) VALUES (1, '[1.0, 2.0, 3.0]')")

          {:ok, entry} = Backup.create()
          entry
        end)

      captured = Path.join(tmp, "notebook-#{entry.id}.db")

      assert File.exists?(captured)
      assert entry.size_bytes > 0
      assert [%{id: id}] = Backup.list()
      assert id == entry.id

      # Read the vector row back OUT of the captured file — the check this test's
      # doc promises, and the one a "file exists" assertion cannot make. ATTACH is
      # refused on the agent's SQL surface but is ordinary SQL on the repo's own
      # connection, so the copy can be inspected without opening a second pool.
      rows =
        Sandbox.unboxed_run(Repo, fn ->
          Repo.query!("ATTACH DATABASE ?1 AS copy", [captured])

          try do
            Repo.query!("SELECT id FROM copy.vec_backup_probe").rows
          after
            Repo.query!("DETACH DATABASE copy")
          end
        end)

      assert rows == [[1]]
    end
  end

  describe "create/1 while the notebook is down" do
    @describetag :notebook_db

    @tag :capture_log
    @tag doc: """
         A capture reads the live database, so a notebook that is not running has
         nothing to read and no number of retries changes that — the answer this
         replaces told the caller to try again, which is advice that cannot be
         followed. The repo is put back before the test ends; leave that out and
         every later test in the run finds no notebook.
         """
    test "answers notebook_down instead of advising a retry" do
      :ok = Supervisor.terminate_child(YmerNode.Supervisor, Repo)

      on_exit(fn ->
        Supervisor.restart_child(YmerNode.Supervisor, Repo)
        Sandbox.mode(Repo, :manual)
      end)

      assert Backup.create() == {:error, :notebook_down}
    end
  end

  describe "restore/1 while the notebook is down" do
    @describetag :notebook_db

    @tag :capture_log
    @tag doc: """
         A restore reaches the down notebook one step later than a capture does:
         `resolve/1` is filesystem-only and answers fine, and the refusal comes
         from the safety capture underneath it. That answer must arrive
         UNRELABELLED — `safety_backup/1` normalises every other capture failure
         to `:restore_failed`, and folding this one in with them would put the
         "try again" advice back on the one state where retrying cannot help. A
         failure here means that pass-through clause went missing.
         """
    test "answers notebook_down rather than the relabelled restore failure", %{tmp: tmp} do
      touch_backup(tmp, @id)
      :ok = Supervisor.terminate_child(YmerNode.Supervisor, Repo)

      on_exit(fn ->
        Supervisor.restart_child(YmerNode.Supervisor, Repo)
        Sandbox.mode(Repo, :manual)
      end)

      assert Backup.restore(@id) == {:error, :notebook_down}
    end
  end

  describe "restore/1" do
    test "rejects a malformed id without touching anything" do
      assert Backup.restore("../escape") == {:error, :invalid_backup_id}
    end

    test "reports a missing backup as not found" do
      assert Backup.restore(@id) == {:error, :backup_not_found}
    end

    @tag :capture_log
    @tag doc: """
         The database path is read after `resolve/1` and before the safety capture.
         A bad id therefore keeps its own answer even when the configuration is
         broken, and a configuration fault answers as the bare pre-capture failure
         with nothing captured — never as a swap outcome, which would name a safety
         backup and tell the lost-work story about an untouched notebook. A failure
         here means the read moved: ahead of `resolve/1`, and a bad id is answered
         with a retry; into the swap, and a config fault claims work was lost.
         """
    test "a missing database path answers before anything is captured", %{tmp: tmp} do
      touch_backup(tmp, @id)
      prev = Application.get_env(:ymer_node, Repo)
      Application.put_env(:ymer_node, Repo, Keyword.delete(prev, :database))
      on_exit(fn -> Application.put_env(:ymer_node, Repo, prev) end)

      assert Backup.restore("../escape") == {:error, :invalid_backup_id}
      assert Backup.restore(@id) == {:error, :restore_failed}
      assert Enum.map(Backup.list(), & &1.id) == [@id]
    end

    @tag :capture_log
    @tag doc: """
         The journal mode is read beside the database path — after `resolve/1`,
         before the safety capture — so a configuration the repo refuses answers
         as the bare pre-capture failure with nothing captured and the repo never
         stopped. It also proves the restore path reads the *configured* mode at
         all: only `Repo.journal_mode/0` refuses `:bogus`. A failure here means
         the read moved into the swap — the answer then names a safety backup
         and invites a retry that fails the same way, writing a safety copy per
         attempt and, at the retention cap, evicting a backup each time — or
         that the restore path stopped reading the configuration.
         """
    test "a refused journal mode answers before anything is captured", %{tmp: tmp} do
      touch_backup(tmp, @id)
      prev = Application.get_env(:ymer_node, Repo)
      Application.put_env(:ymer_node, Repo, Keyword.put(prev, :journal_mode, :bogus))
      on_exit(fn -> Application.put_env(:ymer_node, Repo, prev) end)

      assert Backup.restore(@id) == {:error, :restore_failed}
      assert Enum.map(Backup.list(), & &1.id) == [@id]
      assert Repo.running?()
    end
  end

  describe "restore/1 (integration — repo restart)" do
    @describetag :notebook_db

    @tag doc: """
         The round trip that the whole feature exists for: a row written after the
         capture must be gone once the backup is restored, and the returned
         safety_backup must name a real file. A failure means the swap did not
         take, or the safety backup was not captured — check both before editing.
         """
    test "rolls the store back and returns a usable safety backup", %{tmp: tmp} do
      on_exit(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.query!("DROP TABLE IF EXISTS backup_round_trip")
        end)
      end)

      backup_id =
        Sandbox.unboxed_run(Repo, fn ->
          Repo.query!("DROP TABLE IF EXISTS backup_round_trip")
          Repo.query!("CREATE TABLE backup_round_trip (note TEXT)")

          Repo.query!("INSERT INTO backup_round_trip(note) VALUES ('before capture')")

          {:ok, entry} = Backup.create()

          Repo.query!("INSERT INTO backup_round_trip(note) VALUES ('after capture')")

          entry.id
        end)

      restored =
        Sandbox.unboxed_run(Repo, fn ->
          Backup.restore(backup_id)
        end)

      assert {:ok, result} = restored
      assert result.restored == backup_id
      assert File.exists?(Path.join(tmp, "notebook-#{result.safety_backup}.db"))

      # Mid-test, not `on_exit`: the restore restarted the repo, and the read-back
      # below checks out from the new pool inside this test.
      Sandbox.mode(Repo, :manual)

      notes =
        Sandbox.unboxed_run(Repo, fn ->
          Repo.query!("SELECT note FROM backup_round_trip").rows
        end)

      assert notes == [["before capture"]]
    end

    @tag doc: """
         Runs the restore at `retain: 1` because the round-trip above runs with
         headroom and never exercises the exemption. A failure here means the
         `exempt: [id]` argument was dropped: the restore reports
         `:restore_failed` and the requested backup is gone.
         """
    test "a restore at the retention limit does not prune the backup it is restoring", %{tmp: tmp} do
      on_exit(fn ->
        Sandbox.mode(Repo, :manual)

        Sandbox.unboxed_run(Repo, fn ->
          Repo.query!("DROP TABLE IF EXISTS exempt_probe")
        end)
      end)

      backup_id =
        Sandbox.unboxed_run(Repo, fn ->
          Repo.query!("DROP TABLE IF EXISTS exempt_probe")
          Repo.query!("CREATE TABLE exempt_probe (note TEXT)")
          Repo.query!("INSERT INTO exempt_probe(note) VALUES ('anchor')")

          {:ok, entry} = Backup.create()
          entry.id
        end)

      # Retention of 1 means the safety capture must drop something, and the
      # oldest candidate is the backup being restored.
      Application.put_env(:ymer_node, Backup, directory: tmp, retain: 1)

      restored = Sandbox.unboxed_run(Repo, fn -> Backup.restore(backup_id) end)

      assert {:ok, result} = restored
      assert result.restored == backup_id
      assert File.exists?(Path.join(tmp, "notebook-#{backup_id}.db"))
    end

    @tag :capture_log
    @tag doc: """
         A swap that fails after the safety capture must still hand the capture's
         id back. The failure is forced at the copy — the swap's first step, made to
         fail by chmod'ing the resolved source unreadable — and the copy writes only
         to the temp file beside the database, so the live notebook and its `-wal`
         are untouched. That is why the answer here is the unchanged-and-retryable
         one rather than the lost-work one: the two are told apart by what is left
         on disk, not by which call raised. A failure means either the id went
         missing on the error path again, or a copy that overwrote nothing was
         folded back in with the failures that do.
         """
    test "a swap that fails at the copy leaves the notebook unchanged", %{tmp: tmp} do
      source = touch_backup(tmp, @id)
      File.chmod!(source, 0o000)

      on_exit(fn ->
        Sandbox.mode(Repo, :manual)
        File.chmod(source, 0o600)
      end)

      outcome = Sandbox.unboxed_run(Repo, fn -> Backup.restore(@id) end)

      assert {:error, {:restore_not_started, %{safety_backup: safety}}} = outcome
      assert File.exists?(Path.join(tmp, "notebook-#{safety}.db"))
    end
  end
end
