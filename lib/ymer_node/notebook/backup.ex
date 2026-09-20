defmodule YmerNode.Notebook.Backup do
  @moduledoc """
  Capture and restore for `notebook.db` — the node's one durable obligation.

  Backup is a **notebook operation**, not a subsystem beside the notebook. The
  node holds exactly one database worth retaining, so "take a backup" and "back up
  the notebook" name the same act, and a separate context would be a registry with
  one row in it. A backup is one file: `notebook-<id>.db`, where `<id>` is
  `YYYY-MM-DD-HH-MM-SS` in UTC.

  ## A separate, privileged path — NOT the agent's SQL surface

  `YmerNode.Notebook` is the agent's open-SQL surface; it deliberately blocks
  `ATTACH`/`DETACH` and rolls back writes to contain prompt injection. Capture and
  restore run `VACUUM INTO` and replace the store whole, so they live here, on
  their own path, never reachable through `YmerNode.Notebook.execute/1` or
  `query/1`.

  ## Backups are `VACUUM INTO`, not file copies

  The database runs in WAL mode, so recent commits sit in `notebook.db-wal` until
  checkpointed — a raw file copy would be torn or stale. `VACUUM INTO` writes a
  transactionally consistent, compacted single file with no `-wal`/`-shm`, and it
  copies the `vec0` virtual tables faithfully.

  ## What the caller may see, and what stays opaque

  Ids are opaque handles. `resolve/1` validates one against a strict pattern and
  confirms the resolved file sits inside the backups directory before touching the
  filesystem, which closes path traversal on an id arriving from a worker. Every
  function reachable through the MCP tool catches `File`/`Exqlite` errors, logs the
  path-bearing detail server-side, and returns a path-free atom — a caller that
  forces a failure never reads back a filesystem path.

  ## Restore is destructive, and its undo is automatic

  `restore/1` overwrites the entire current database. It captures an ordinary
  backup of the *current* state first — the safety backup, whose id is returned so
  the roll-back can itself be rolled back — then quiesces the pool by stopping the
  repo, and swaps the file.

  Order inside the down window is load-bearing, and the first step is a refusal.
  The temp path beside the store is cleared of anything an earlier restore left
  there — a copy, or the `-wal`/`-shm` a switch that never closed cleanly leaves
  beside one — because a stale WAL beside the next copy would be replayed into
  it by the very open that checks it. Then the copy is checked **before**
  anything is overwritten: a raw handle opens `notebook.db.restore-tmp` and
  switches it to the journal mode the pool is configured for, and a file SQLite
  cannot read as a database refuses at that statement, so the restore stops with
  the live store and its `-wal` untouched and the caller is told to choose another
  backup. The refused copy is removed on the way out, so a rejected backup leaves
  nothing beside the store either. Then clear the stale `-wal`/`-shm` **before**
  renaming the new file into place, never after. Clearing them is non-negotiable
  — leave a stale WAL beside the new file and SQLite replays the old WAL onto it
  and corrupts it — and doing the `rm` first closes the crash-mid-swap window: a
  kill between rename and a later `rm` would pair the *new* database with the
  *old* WAL, the exact corruption this feature exists to prevent. With
  clear-then-check-then-`rm`-then-`rename`, every crash point leaves a consistent
  file — the old database with its own WAL, or the new one with no WAL — and
  nothing recoverable is lost, because the safety backup already captured the
  current committed state with the repo up, so its `VACUUM INTO` read the live
  WAL.

  The switch earns its place twice. A `VACUUM INTO` member is a rollback-journal
  database, so switching the copy before the rename means the restarted pool's
  first connections meet a file already in the journal mode they are configured
  to set instead of racing each other to convert it — the "database is locked"
  line every restore used to log. And it is what keeps a file that will never
  open out of the live store at all: without it the restart answers `{:ok, …}`
  for a repo whose every query then fails, and the standing instruction to
  restart the app becomes a boot that never completes.

  The safety capture is an ordinary backup and counts against retention like any
  other, with one exception: it is taken with the backup being restored exempt
  from that prune. At the retention limit the capture would otherwise drop the
  oldest backup, which may be the very one whose path was just resolved.

  ```mermaid
  sequenceDiagram
      autonumber
      participant C as MCP caller (holds Lock)
      participant R as YmerNode.Notebook.Repo
      participant S as YmerNode.Supervisor
      participant F as Filesystem
      C->>F: resolve the chosen backup (before anything destructive)
      C->>R: VACUUM INTO (safety backup, repo UP)
      C->>S: terminate_child(repo)
      C->>F: clear notebook.db.restore-tmp and its -wal/-shm (a leftover, if any)
      C->>F: cp chosen backup → notebook.db.restore-tmp
      C->>F: open the copy, switch it to the configured journal mode — refuses a file that is not a database
      C->>F: rm notebook.db-wal, notebook.db-shm (stale, before the rename)
      C->>F: rename notebook.db.restore-tmp → notebook.db (atomic, same fs)
      C->>S: restart_child(repo), whatever the swap answered
      Note over R: init/2 reloads vec0 on the restarted pool
      C->>R: SELECT 1 — serving, not serving, or down
      Note over C: the swap's answer and the restart's answer are combined last
  ```

  **Restart is best-effort, not an absolute guarantee.** `with_repo_down/2`
  restarts the repo whatever the body answered or raised. An untrappable kill of
  the caller mid-window, or a failed `restart_child`, can leave the repo down
  until the app restarts — the supervisor is `:one_for_one` and will not
  auto-recreate a deliberately-terminated child. The recovery for a *down repo* is
  an app restart, which boots onto the atomically-swapped file. The safety backup
  is the **data** undo and presupposes a live repo; it is not the recovery path
  for a down repo. The down window is one filesystem swap and the dominant
  failure — the swap raising — is handled, so this residual is accepted rather
  than redesigned around a supervised swap-owner.

  **A store the node cannot open is the operator's to recover**, deliberately and
  by hand; the README's layout section is the guide. A restore will not do it: the
  safety capture reads the live database, so on a store that will not open there
  is nothing to capture, and overwriting it with no copy would be data loss under
  the node's own hand on the one store the node exists to keep. `create/1` and
  `restore/1` therefore answer `:notebook_not_serving` and touch nothing.

  **What is not accepted is reporting independent outcomes as one.** A restore has
  two answers — whether the swap landed, and what the notebook can do
  afterwards — and collapsing them loses the more valuable one: a restore that
  landed and then failed to restart was reported as a plain failure, so the caller
  retried a swap that had already happened, and the id of the backup that would
  undo it went with the error. `with_repo_down/2` therefore captures the body's
  outcome, attempts the restart, asks the pool one statement, and returns both
  facts; `restore_outcome/3` combines them, and every answer that could have
  changed the store names that backup.

  ## What this module coordinates

  ```mermaid
  flowchart TD
      B[YmerNode.Notebook.Backup]

      subgraph owned["Owned"]
          LK[Backup.Lock]
      end

      subgraph external["External"]
          NR[Notebook.Repo]
          SUP[YmerNode.Supervisor]
          SQ[Exqlite.Sqlite3]
          FS[(backups directory)]
      end

      B -->|"serialises capture and restore"| LK
      B -->|"VACUUM INTO, and one statement after the restart"| NR
      B -->|"terminate and restart during a restore"| SUP
      B -->|"opens the copy off-pool to check and switch it"| SQ
      B -->|"backup files, retention"| FS
  ```

  Concurrency: a capture or restore is rejected while either is in progress — see
  `YmerNode.Notebook.Backup.Lock`.
  """
  alias Exqlite.Sqlite3
  alias YmerNode.Notebook.Backup.Lock
  alias YmerNode.Notebook.Repo

  import Repo, only: [is_journal_mode: 1]

  require Logger

  @default_retain 40
  @member_prefix "notebook"

  # Anchored with \A...\z, NOT ^...$: without the /m flag PCRE's $ still matches
  # just before a trailing newline, so "2026-06-28-14-30-05\n" would pass ^...$.
  # @id_re validates the untrusted MCP `id` at the trust boundary, so it must bind
  # to the absolute string end; @member_re follows for consistency (its trailing
  # \.db already blocks the newline, so there it is hygiene).
  @id_re ~r/\A\d{4}-\d{2}-\d{2}-\d{2}-\d{2}-\d{2}\z/
  @member_re ~r/\A#{@member_prefix}-(?<id>\d{4}-\d{2}-\d{2}-\d{2}-\d{2}-\d{2})\.db\z/

  # A supervised restart of the lock is microseconds — measured at 2-54 µs over
  # 200 runs — so an acquire that exits inside one is waited out rather than
  # answered. The repo's own wait, `YmerNode.Notebook.Repo.await_running/0`, keeps
  # the same budget for the same reason; the two are separate because they wait
  # on different processes.
  @lock_wait_ms 50
  @lock_poll_ms 5

  # ─── Runtime configuration ──────────────────────────────────────────

  @doc """
  Absolute path to the backups directory
  (`config :ymer_node, YmerNode.Notebook.Backup, :directory`).
  """
  def directory do
    :ymer_node
    |> Application.get_env(__MODULE__, [])
    |> Keyword.fetch!(:directory)
  end

  @doc """
  How many backups to keep (`config :ymer_node, YmerNode.Notebook.Backup, :retain`,
  default #{@default_retain}). The oldest beyond the limit are pruned after each
  successful capture.
  """
  def retain do
    :ymer_node
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:retain, @default_retain)
  end

  # ─── Public API ─────────────────────────────────────────────────────

  @doc """
  Captures a backup: one id, one `VACUUM INTO`, then a prune to `retain/0`
  oldest-first. Returns `{:ok, entry}` — the same shape `list/0` rows carry —
  `{:error, :operation_in_progress}` if a capture or restore is already running,
  `{:error, :notebook_down}` if the notebook is not running once the repo's own
  bounded wait has passed (a capture reads the live database, so a stopped repo
  has nothing to read; a repo inside a supervised restart is waited for and then
  read), `{:error, :notebook_not_serving}` if it is running and the node cannot
  open the store (the same is true, one layer down), or `{:error, :backup_failed}`
  if the file cannot be written, in which case the partial output is removed so a
  corrupt backup never appears in `list/0`.

  `{:error, :notebook_down}` is also the answer when `YmerNode.Notebook.Backup.Lock`
  stays unreachable past its own restart window — its `with_lock/2` names the
  two exits behind that answer. The notebook may be serving on that route — it
  is the lock that is unreachable, not the repo — but no capture or restore can
  be serialised without the lock, and a node restart is the one action that
  brings it back, which is what the message asks for.

  Options:

    * `:prune` — set `false` to keep every existing backup.
    * `:exempt` — ids this call's prune must never drop. The restore passes the id
      being restored: at the retention limit the safety capture would otherwise
      prune the very backup being restored, which `resolve/1` has already turned
      into a path, failing the swap mid-restore.

  Path-opacity boundary: a `File`/`Exqlite` error is logged server-side and never
  reaches the caller as a path.
  """
  def create(opts \\ []) when is_list(opts) do
    locked(:backup, fn -> do_create(opts) end)
  rescue
    e -> opaque_failure(e, :backup_failed, "create backup")
  end

  @doc """
  Lists backups, newest first: `%{id, created_at, size_bytes}`. Returns
  `{:error, :backups_failed}` if the backups directory cannot be read — a
  path-opacity boundary, since the underlying `File` errors embed absolute paths.
  """
  def list do
    dir = ensure_dir!()

    dir
    |> File.ls!()
    |> Enum.flat_map(&parse_member/1)
    |> Enum.flat_map(&listed_entry(&1, dir))
    |> Enum.sort_by(& &1.id, :desc)
  rescue
    e -> opaque_failure(e, :backups_failed, "list backups")
  end

  @doc """
  Maps an opaque backup id to its file path. Returns `{:ok, path}`,
  `{:error, :invalid_backup_id}` when the id is not a bare `YYYY-MM-DD-HH-MM-SS`
  token, or `{:error, :backup_not_found}`. The strict pattern and the in-directory
  check together make path traversal unrepresentable — the argument arrives from
  the worker.
  """
  def resolve(id) when is_binary(id) do
    with :ok <- check_id(id), do: existing_member(id)
  end

  @doc """
  Restores `notebook.db` from backup `id`. DESTRUCTIVE: replaces the whole
  database. Captures the **safety backup** first — an ordinary backup of the
  pre-restore state, whose id is what the caller restores to undo this restore —
  then stops the repo and swaps the file. Returns
  `{:ok, %{restored: id, safety_backup: id}}`.

  Every answer past that capture that could have changed the store names the
  safety backup, because once the swap has started overwriting it is not a
  nicety: the old database has lost its `-wal`, so a commit made shortly before
  the restore survives only there.

    * `{:error, {:restored_notebook_down, %{restored: id, safety_backup: id}}}` —
      the swap landed and the repo did not come back.
    * `{:error, {:restored_notebook_not_serving, %{restored: id, safety_backup: id}}}` —
      the swap landed, the repo came back, and it cannot open the store it now has.
    * `{:error, {:backup_unreadable, %{safety_backup: id}}}` — the chosen backup
      does not open as a database and the notebook is serving as it was: nothing
      was overwritten, and another backup is the way forward.
    * `{:error, {:restore_incomplete, %{safety_backup: id}}}` — the swap failed
      after it had begun overwriting, so the safety backup is the recovery.
    * `{:error, {:restore_not_started, %{safety_backup: id}}}` — nothing was
      touched and the notebook is serving as it was, so retrying is safe: either
      the repo could not be stopped, or the copy or its check stopped before the
      live database was overwritten.

  When nothing was overwritten and the notebook did **not** come back, the answer
  is the bare `{:error, :notebook_down}` or `{:error, :notebook_not_serving}`
  instead: "retry" and "choose another backup" are instructions that cannot come
  true for a notebook that cannot take a call, the store is as it was, and the
  safety backup is an ordinary backup in `list/0` with nothing to undo.

  Before that capture there is no id to name: `{:error, :operation_in_progress}`,
  `{:error, :invalid_backup_id}`, `{:error, :backup_not_found}`,
  `{:error, :notebook_down}` when the notebook is not running once the repo's
  bounded wait has passed — or when `YmerNode.Notebook.Backup.Lock` stays
  unreachable past its own restart window (its `with_lock/2` names the exits
  behind that answer), where the notebook may be serving but nothing can be
  serialised and a node restart is the one action that brings the lock back —
  `{:error, :notebook_not_serving}` when it is running
  and the node cannot open the store — nothing is captured and nothing is
  overwritten, and recovering such a store is the operator's, by hand — and
  `{:error, :restore_failed}` from the `rescue` below. That `rescue` sits on this
  function rather than inside the swap, so a `File`/`Exqlite` error is logged
  server-side and never reaches the caller as a path, whichever step raised it —
  the swap's own raise is caught earlier, where the safety backup's id is still in
  scope.
  """
  def restore(id) when is_binary(id) do
    locked(:restore, fn -> do_restore(id) end)
  rescue
    e -> opaque_failure(e, :restore_failed, "restore the notebook")
  end

  @doc """
  Replaces the live database with the bytes of backup `src`, in two phases. Up to
  the point of no return: clears anything an earlier restore left at the temp
  path beside the store, copies `src` there, and **checks that the copy opens as
  a database** by switching it to `mode`, one of the journal modes
  `YmerNode.Notebook.Repo.is_journal_mode/1` admits. Past it: removes
  the stale `-wal`/`-shm`, then renames the temp into place atomically on the
  same filesystem. Order is load-bearing — see the module doc.

  Returns `:ok`; `{:error, :backup_unreadable}` when the copy does not open, in
  which case nothing has been overwritten and the refused copy is removed again,
  so the store's directory is left exactly as it was found; or
  `{:error, :swap_not_started}` when anything else stopped the first phase — a
  leftover the node could not clear, a copy that failed — which is the same
  promise about the store with a different way forward. Only the second phase
  RAISES: removing the WAL is mandatory, and removal fails loudly on a real
  (non-`:enoent`) error so a restore fails rather than corrupts. The caller MUST
  have stopped the repo first. The original `src` is preserved — the check runs
  on the copy, so no member on disk is ever mutated.
  """
  def swap_into_place(src, db, mode)
      when is_binary(src) and is_binary(db) and is_journal_mode(mode) do
    tmp = db <> ".restore-tmp"

    with :ok <- prepare_copy(src, tmp, mode), do: overwrite!(tmp, db)
  end

  @doc """
  Stops `repo`, closing the pool so nothing holds the file, runs `fun` with the
  repo DOWN, then restarts it — always, whatever `fun` answered or raised.

  The body's outcome and the notebook's serving state are separate facts and come
  back as separate facts:

    * `{:done, value, :serving | :not_serving | :down}` — `fun` returned `value`,
      and the notebook came back serving, came back registered but unable to open
      its store, or did not come back at all. A failed restart is logged
      server-side; it never replaces `value`.
    * `{:not_started, reason}` — the repo could not be stopped, so `fun` never ran
      and nothing was touched. `Supervisor.terminate_child/2`'s only error is
      `:not_found`, so in practice this means the child spec has gone.

  The third value is three-valued because registration is not service:
  `Supervisor.restart_child/2` answers `{:ok, pid}` for a repo whose connections
  will fail asynchronously, so the restart is followed by one statement through
  the pool — see `restart_repo/1`.

  A raising `fun` is re-raised with its original kind and stacktrace *after* the
  restart attempt, so an unexpected failure is never quietly converted. The restore
  path catches the swap's raise in its own body before it reaches here, which is
  what keeps the safety backup's id on that answer.

  Public ONLY so the outcome split can be unit-tested directly; it has no MCP
  exposure and is called by the restore path alone. Best-effort, not an absolute
  guarantee — the module doc states the residual and its recovery.
  """
  def with_repo_down(repo, fun) when is_atom(repo) and is_function(fun, 0) do
    case Supervisor.terminate_child(YmerNode.Supervisor, repo) do
      :ok ->
        run_with_repo_down(repo, fun)

      {:error, reason} ->
        Logger.error("notebook restore: could not stop #{inspect(repo)}: #{inspect(reason)}")
        {:not_started, reason}
    end
  end

  @doc """
  Combines a `with_repo_down/2` outcome for the swap with the ids the restore
  holds — `restored`, the backup asked for, and `safety_backup`, the one taken
  just before the swap — into the answer the caller gets.

  A swap that did not land splits by what it left on disk, which its reason
  carries. Two reasons mean nothing was overwritten — `:backup_unreadable`, the
  copy was refused before the first removal, and `:swap_not_started`, the copy or
  its check stopped before it — and for those the notebook's state after the
  restart decides the answer: serving, and the caller is told what was wrong with
  this attempt — a different backup is the way forward for one, a retry is honest
  for the other; not serving or down, and the bare `:notebook_not_serving` /
  `:notebook_down` answers go back instead, because "retry" and "choose another
  backup" are instructions that cannot come true for a notebook that did not
  come back, and the store is as it was, so there is nothing for a safety
  backup's id to undo. Any other reason means the old database is no longer
  whole, and the safety backup is the recovery whatever the notebook then did.

  A swap that did land splits by the notebook's serving state, and the two failure
  answers go to different observers: `:down` is a process that is gone and an app
  restart brings it back onto the restored data; `:not_serving` is a file the
  operator has to look at, because the restart landed and the pool still cannot
  open the store it now has. With the pre-swap check in front of it that second
  answer is the residual of residuals — a copy that opened off-pool and that the
  restarted pool still cannot serve — and it is answered rather than folded into
  the first precisely because the two ask for different things.

  Public ONLY so every answer is directly testable. Two of the INPUTS cannot be
  forced through `restore/1` from a test: `Supervisor.restart_child/2` answers
  `{:ok, pid}` even for a repo pointed at a database it cannot open, because the
  pool's connections fail later and asynchronously, so a restart cannot be made to
  fail from outside the window; and `Supervisor.terminate_child/2`'s only error
  needs an absent child spec, which the safety capture's own liveness check has
  already refused by the time the swap runs. Two of the ANSWERS are reachable
  regardless: `{:restore_not_started, …}` is also what a copy that failed before
  anything was overwritten gets, and `{:backup_unreadable, …}` is what any file
  that is not a database gets — an unreadable source forces both from a test.
  """
  def restore_outcome(outcome, restored, safety_backup)
      when is_binary(restored) and is_binary(safety_backup) do
    ids = %{restored: restored, safety_backup: safety_backup}

    case outcome do
      {:done, :ok, serving} ->
        landed(serving, ids)

      {:done, {:error, reason}, serving}
      when reason in [:backup_unreadable, :swap_not_started] ->
        untouched(serving, reason, safety_backup)

      {:done, {:error, _swap}, _serving} ->
        {:error, {:restore_incomplete, %{safety_backup: safety_backup}}}

      {:not_started, _reason} ->
        {:error, {:restore_not_started, %{safety_backup: safety_backup}}}
    end
  end

  @doc """
  The id `dt` allocates in `dir`: `YYYY-MM-DD-HH-MM-SS` in UTC, advanced one
  second at a time while a backup file already exists at that id. Serialized by
  the lock, so this almost never iterates.

  Public ONLY so the collision branch is directly testable. The scan is
  load-bearing beyond id hygiene: `VACUUM INTO` refuses an existing target, so
  reusing an id would fail the capture and send `create/1` down its cleanup path,
  which removes the file at that id — the pre-existing backup's.
  """
  def allocate(%DateTime{} = dt, dir) when is_binary(dir) do
    id = format_id(dt)

    if File.exists?(member_path(id, dir)),
      do: allocate(DateTime.add(dt, 1, :second), dir),
      else: id
  end

  @doc """
  Drops the oldest backups beyond `retain/0`. Ids in `exempt` are never dropped,
  even when they are the oldest.

  Public ONLY so retention is directly testable; it is called by `create/1` after
  a successful capture — never before, so a failed capture cannot cost an existing
  backup. A removal failure is tolerated: pruning must never turn a successful
  capture into an error.
  """
  def prune_to_retain(exempt \\ []) when is_list(exempt) do
    # list/0 is a path-opacity boundary: it converts an unreadable directory into
    # {:error, :backups_failed} rather than raising. Match on that instead of
    # piping it into Enum.drop/2 — the tuple is not enumerable, and the raise
    # would surface from create/1's rescue as :backup_failed on a capture that
    # already succeeded, which is exactly what this function promises not to do.
    case list() do
      entries when is_list(entries) -> drop_beyond_retain(entries, exempt)
      {:error, _reason} -> :ok
    end
  end

  # ─── Private ────────────────────────────────────────────────────────

  # Path-opacity boundary. `File`/`Exqlite` error messages embed absolute paths;
  # log the path-bearing detail server-side and return a path-free atom so a
  # worker that forces a failure cannot read back the backups directory or the
  # database path.
  defp opaque_failure(exception, atom, verb) do
    Logger.error("notebook backup #{verb} failed: #{Exception.message(exception)}")
    {:error, atom}
  end

  # Both entry points take the lock through here. `Lock.with_lock/2` contains its
  # own exits, so a lock inside its restart window answers `:lock_unreachable`
  # rather than exiting into this rescue — and that answer is not
  # `:operation_in_progress`: nothing is holding the lock, so telling the caller
  # to wait for an operation to finish would be false. Nothing has run when it
  # arrives, which is what makes retrying the whole operation safe.
  defp locked(op, fun) do
    case Lock.with_lock(op, fun) do
      {:error, :lock_unreachable} -> locked_after_wait(op, fun)
      other -> other
    end
  end

  # A lock still unreachable after the restart window — `Lock.with_lock/2` names
  # the two exits behind that answer — gets the app-restart instruction, the
  # same one a stopped repo gets, and for the same reason: it is the one action
  # that brings the lock back, whichever exit it was.
  defp locked_after_wait(op, fun) do
    if await_lock(System.monotonic_time(:millisecond) + @lock_wait_ms) do
      case Lock.with_lock(op, fun) do
        {:error, :lock_unreachable} -> {:error, :notebook_down}
        other -> other
      end
    else
      {:error, :notebook_down}
    end
  end

  # Keyed on a monotonic deadline, not on the sleeps taken, because the poll can
  # block: `Lock.current/0` costs the Lock's call timeout against a lock that is
  # alive and not answering, and a wait that counted only its sleeps would then
  # poll that timeout ten times over — measured at 5.5 s for a stated budget of
  # 50 ms. With the deadline read after each poll, one such poll is the last.
  defp await_lock(deadline) do
    Process.sleep(@lock_poll_ms)

    cond do
      Lock.current() != :unreachable -> true
      System.monotonic_time(:millisecond) >= deadline -> false
      true -> await_lock(deadline)
    end
  end

  defp drop_beyond_retain(entries, exempt) do
    dir = directory()

    entries
    |> Enum.drop(retain())
    |> Enum.reject(&(&1.id in exempt))
    |> Enum.each(&File.rm(member_path(&1.id, dir)))
  end

  defp ensure_dir! do
    dir = directory()
    File.mkdir_p!(dir)
    dir
  end

  defp check_id(id) do
    if Regex.match?(@id_re, id), do: :ok, else: {:error, :invalid_backup_id}
  end

  defp existing_member(id) do
    dir = ensure_dir!()
    path = member_path(id, dir)

    if File.exists?(path) and within_dir?(path, dir),
      do: {:ok, path},
      else: {:error, :backup_not_found}
  end

  # Captures with the LOCK ALREADY HELD — create/1 takes it, and the restore path
  # calls this directly because it is already inside the lock. A capture reads the
  # live database, so a stopped notebook has nothing to read: answer that rather
  # than let the VACUUM's lookup failure raise into a "try again" the caller cannot
  # act on. The read waits through the repo's own bounded wait first, so a capture
  # that lands in a supervised restart — microseconds, and self-healing — is
  # served rather than told to restart the node.
  defp do_create(opts) do
    if Repo.await_running(), do: create_member(opts), else: {:error, :notebook_down}
  end

  defp create_member(opts) do
    dir = ensure_dir!()
    id = allocate(DateTime.utc_now(), dir)

    # The path is server-allocated, never from the agent, so the bound parameter
    # is the only input, and allocate/2 already proved no file pre-exists.
    case Repo.query("VACUUM INTO ?1", [member_path(id, dir)]) do
      {:ok, _result} ->
        maybe_prune(id, opts)
        {:ok, entry(id, dir)}

      {:error, reason} ->
        # VACUUM INTO does not promise to remove a partial output — SQLite's docs
        # say it "might be incomplete and corrupt" — and allocate/2 ensured this
        # path did not pre-exist, so the removal targets only this call's output.
        File.rm(member_path(id, dir))
        Logger.error("notebook backup VACUUM INTO failed: #{inspect(reason)}")
        capture_failure(reason)
    end
  end

  # A capture reaches the pool the same way every query does, so it meets the same
  # failure — here as a RETURNED tuple rather than a raise. A store the node
  # cannot open is not a backup that failed to write: the first cannot be retried
  # into working, and saying so is the difference between an instruction the
  # caller can act on and one it cannot.
  defp capture_failure(reason) do
    if Repo.not_serving?(reason),
      do: {:error, :notebook_not_serving},
      else: {:error, :backup_failed}
  end

  # Resolve BEFORE capturing — the source must exist before anything destructive
  # happens — then capture with the resolved id exempt, so the safety capture
  # cannot prune its own restore source at the retention limit. Resolving first
  # also means a bad id is answered as a bad id even while the notebook is down:
  # that answer is true, filesystem-only, and cheaper to act on than a restart.
  # The database path and the journal mode are read after the id resolves — so a
  # bad id keeps its own answer whatever the configuration — and before anything
  # is captured or stopped, so a configuration fault answers as the bare
  # pre-capture failure: a config read that failed inside the down window would
  # be answered as a retryable swap failure, and each retry would fail the same
  # way after writing another safety copy. This comment owns that ordering;
  # swap/3's rescue covers the call to swap_into_place/3 alone because of it.
  defp do_restore(id) do
    with {:ok, src} <- resolve(id),
         db = Repo.database_path(),
         mode = Repo.journal_mode(),
         {:ok, safety} <- safety_backup(id) do
      outcome = with_repo_down(Repo, fn -> swap(src, db, mode) end)
      restore_outcome(outcome, id, safety.id)
    end
  end

  # swap_into_place/3 answers :ok, answers {:error, :backup_unreadable} when the
  # copy does not open as a database, answers {:error, :swap_not_started} when
  # anything else stopped it before the first removal, or RAISES. Only the raise
  # is caught here — the two refusals are values and pass through this function
  # untouched, to be classified with the rest by restore_outcome/3. The raise is
  # caught HERE rather than at restore/1's function-level rescue: by the time it
  # reached there the safety backup's id would be out of scope, and past the
  # first removal that id is the only place a commit made shortly before the
  # restore can still be — the old database has lost its -wal by then. Path-free
  # by the same rule as everywhere else.
  #
  # One reason, not two, because swap_into_place/3 splits its phases itself:
  # everything before the first removal is rescued inside it and answered as
  # :swap_not_started, so the only raise that can reach this rescue comes from
  # the WAL/SHM removal or the rename — at or past the point where the old
  # database stops being whole. The removals raise the same error for -wal and
  # -shm and telling them apart would mean matching on paths, so the first of
  # them is taken as the point of no return.
  #
  # The rescue covers the call to swap_into_place/3 alone: both configuration
  # reads happen in do_restore/1, ahead of the safety capture — its comment owns
  # why — so a refused value never reaches here.
  defp swap(src, db, mode) do
    swap_into_place(src, db, mode)
  rescue
    e -> opaque_failure(e, :swap_failed, "swap the restored file into place")
  end

  # Everything up to the point of no return, and rescued as a whole. Nothing in
  # here touches the live database or its `-wal`, so a raise from any of it — the
  # leftover it could not clear, the copy, the check — leaves the store exactly as
  # it was, and the honest answer is the retryable one whichever step raised. The
  # split is by PHASE, deliberately: the earlier split by exception type reported a
  # raise from the check as an overwrite that never happened.
  defp prepare_copy(src, tmp, mode) do
    clear_restore_tmp!(tmp)
    File.cp!(src, tmp)

    case switch_journal_mode(tmp, mode) do
      :ok ->
        :ok

      {:error, _reason} = refused ->
        # The copy this function wrote is this function's to clean up, the same
        # way `do_create/1` removes a partial `VACUUM INTO` output. Best-effort:
        # a raise here would turn the refusal into `:swap_not_started`, whose
        # instruction — retry — is the wrong one for a backup that will not open.
        discard_copy(tmp)
        refused
    end
  rescue
    e ->
      # Reached with a whole copy at the temp path, a half-written one, or —
      # when the clear itself raised — nothing this call wrote. The path is the
      # node's own in every case (`clear_restore_tmp!/1`'s rule), so the removal
      # is best-effort on the same terms and for the same reason as the refusal
      # above; where the clear raised, it re-attempts a removal that fails the
      # same way and changes nothing.
      discard_copy(tmp)
      opaque_failure(e, :swap_not_started, "copy the backup into place")
  end

  # Past the point of no return: from the first removal on, the old database is no
  # longer whole. Every raise from here reaches `swap/2`'s rescue as the answer
  # that says so, and nothing here is rescued locally.
  defp overwrite!(tmp, db) do
    Enum.each(sidecars(db), &rm_if_present!/1)
    File.rename!(tmp, db)
    :ok
  end

  # The temp path is the node's own, and so is anything already at it: a copy an
  # earlier restore did not get to remove, or the `-wal`/`-shm` a switch that
  # never closed cleanly left beside one. The `-wal` is the dangerous one — a valid
  # WAL beside the next copy to appear at this path is replayed into it by the
  # very open that is meant to check it, and the file that lands is the member
  # paired with another database's frames. Cleared with the raising removal: a
  # leftover the node cannot clear stops the restore before anything is written,
  # inside the phase whose raises are answered as nothing having started.
  defp clear_restore_tmp!(tmp) do
    Enum.each(restore_tmp_files(tmp), &rm_if_present!/1)
  end

  defp discard_copy(tmp) do
    Enum.each(restore_tmp_files(tmp), &File.rm/1)
  end

  defp restore_tmp_files(tmp), do: [tmp | sidecars(tmp)]

  # The files SQLite keeps beside a database, named once for both phases: the
  # temp copy's, which the first phase clears, and the store's own, which the
  # second removes before the rename.
  defp sidecars(path), do: [path <> "-wal", path <> "-shm"]

  # The journal-mode switch the restored copy needs is also the check that it
  # opens as a database. `Sqlite3.open/1` hands back a handle for anything — it
  # creates the file if it is absent — so the FIRST STATEMENT is what refuses a
  # file SQLite cannot read: measured, random bytes answer "file is not a
  # database" and a half-copied member answers "database disk image is
  # malformed", both in under a millisecond. An empty file passes and becomes a
  # fresh empty database, which is a domain rule and not a gap: refusing it would
  # need a rule about what a notebook must contain, and a fresh store has no
  # tables either.
  #
  # `mode` is the pool's own, the caller's to read and bounded at
  # swap_into_place/3's head, so the copy meets the pool already in the mode its
  # connections will set: on the default `:wal` node this is the WAL switch, and
  # on a node configured otherwise it is whatever that node runs — never WAL
  # unconditionally, which would have every connection of a non-WAL pool convert
  # the file back.
  #
  # It is a raw, off-pool handle deliberately. The pool is stopped inside the down
  # window, and the file being checked is not the store yet — it is a copy at a
  # temp path that no connection has ever seen.
  defp switch_journal_mode(path, mode) do
    case Sqlite3.open(path) do
      {:ok, db} -> switch_open_copy(db, path, mode)
      {:error, reason} -> unreadable(path, reason)
    end
  end

  # The handle is closed on both paths, and a clean close checkpoints and removes
  # the `-wal`/`-shm` the switch created — so the rename that follows moves one
  # file and leaves no orphans beside the store. The close's own answer is not
  # read: a close that fails leaves at most a `-wal`/`-shm` beside the temp copy,
  # which the next restore's `clear_restore_tmp!/1` removes before it copies.
  defp switch_open_copy(db, path, mode) do
    switched = Sqlite3.execute(db, "PRAGMA journal_mode=#{mode}")
    Sqlite3.close(db)

    case switched do
      :ok -> :ok
      {:error, reason} -> unreadable(path, reason)
    end
  end

  # Path-opacity boundary, like every other failure here: the path is logged
  # server-side and the caller gets a path-free atom. The atom over-approximates,
  # deliberately: the driver hands back the failure's text and no code, so a disk
  # that is full or read-only refuses at the same statement as a file that is not
  # a database, and nothing structural tells them apart. The caller's message
  # therefore says what is true of both — the copy could not be opened this time
  # and nothing was overwritten — and never that the backup itself is beyond use.
  defp unreadable(path, reason) do
    Logger.error("notebook restore: #{path} does not open as a database: #{inspect(reason)}")
    {:error, :backup_unreadable}
  end

  # The safety capture is an ORDINARY backup: a normal id, no kind label, no
  # exemption from retention beyond THIS restore's prune. do_create/1 normalises
  # its own failure to :backup_failed; relabel it so the caller-facing message
  # names the operation actually attempted — except the two that already name the
  # only thing wrong, and that would read as retryable if they were relabelled.
  # Both of those also mean the restore stops here, with nothing captured and
  # nothing overwritten, which is the whole point: a store the node cannot read is
  # not one to overwrite with no copy of it.
  defp safety_backup(id) do
    case do_create(exempt: [id]) do
      {:ok, _entry} = ok -> ok
      {:error, :notebook_down} = down -> down
      {:error, :notebook_not_serving} = not_serving -> not_serving
      {:error, _other} -> {:error, :restore_failed}
    end
  end

  defp maybe_prune(id, opts) do
    if Keyword.get(opts, :prune, true),
      do: prune_to_retain([id | Keyword.get(opts, :exempt, [])]),
      else: :ok
  end

  defp format_id(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d-%H-%M-%S")

  defp parse_member(name) do
    case Regex.named_captures(@member_re, name) do
      %{"id" => id} -> [id]
      nil -> []
    end
  end

  defp entry(id, dir) do
    %{
      id: id,
      created_at: id_to_iso8601(id),
      size_bytes: File.stat!(member_path(id, dir)).size
    }
  end

  # Listing-only variant, returning [] for a member that has vanished. `list/0`
  # holds no lock, so a concurrent capture's retention prune can delete the
  # oldest file between `File.ls!` and the `stat` — through the bang `entry/2`
  # that is `:enoent`, and skipping what is no longer there is the honest answer
  # for a listing that is already an over-approximation of the directory. Every
  # OTHER `File.Error` (EACCES, EIO — a real fault, not the race) re-raises into
  # `list/0`'s rescue, so it is logged and answered as `{:error, :backups_failed}`
  # instead of silently shortening the list — while `create/1`'s call keeps the
  # bang, where a missing file it just wrote IS a fault.
  defp listed_entry(id, dir) do
    [entry(id, dir)]
  rescue
    e in File.Error ->
      if e.reason == :enoent, do: [], else: reraise(e, __STACKTRACE__)
  end

  # Derives an ISO-8601 UTC string straight from the id's fields — no DateTime math.
  defp id_to_iso8601(id) do
    [y, mo, d, h, mi, s] = String.split(id, "-")
    "#{y}-#{mo}-#{d}T#{h}:#{mi}:#{s}Z"
  end

  defp member_path(id, dir), do: Path.join(dir, "#{@member_prefix}-#{id}.db")

  defp within_dir?(path, dir), do: Path.dirname(Path.expand(path)) == Path.expand(dir)

  # The restart must happen whatever the body did, and must not be able to replace
  # what the body answered — which is exactly what an `after` clause could not
  # give: a raise from `after` replaces the body's return value, so a restore that
  # had already landed was reported as a plain failure. Catch every kind, restart,
  # then decide; `:erlang.raise/3` puts an error, exit or throw back exactly as it
  # arrived, stacktrace included.
  defp run_with_repo_down(repo, fun) do
    outcome =
      try do
        {:returned, fun.()}
      catch
        kind, reason -> {:raised, kind, reason, __STACKTRACE__}
      end

    serving = restart_repo(repo)

    case outcome do
      {:returned, value} -> {:done, value, serving}
      {:raised, kind, reason, stacktrace} -> :erlang.raise(kind, reason, stacktrace)
    end
  end

  # Answers the notebook's serving state rather than raising: the caller pairs it
  # with the body's own outcome, and a raise here would overwrite that outcome.
  # The failure detail is logged server-side and is path-free.
  defp restart_repo(repo) do
    case Supervisor.restart_child(YmerNode.Supervisor, repo) do
      {:ok, _child} ->
        serving_state()

      {:ok, _child, _info} ->
        serving_state()

      {:error, :running} ->
        serving_state()

      {:error, reason} ->
        Logger.error("notebook restore: #{inspect(repo)} failed to restart: #{inspect(reason)}")
        :down
    end
  end

  # The restart's own answer is registration, not service — `restart_child/2`
  # answers `{:ok, pid}` for a repo whose connections will fail asynchronously, so
  # a restore onto an unopenable file used to report success. One statement
  # through the pool is the only channel that measures the serving path; an
  # off-pool open would pass a file the pool is still backing off from. It runs
  # once, inside an operation that is already multi-second, and it must not raise.
  defp serving_state do
    case Repo.query("SELECT 1") do
      {:ok, _result} -> :serving
      {:error, reason} -> restarted_not_serving(reason)
    end
  catch
    _kind, reason -> restarted_no_answer(reason)
  end

  defp restarted_not_serving(reason) do
    Logger.error("notebook restore: the restarted repo cannot open the store: #{inspect(reason)}")
    :not_serving
  end

  defp restarted_no_answer(reason) do
    Logger.error("notebook restore: the restarted repo did not answer: #{inspect(reason)}")
    :down
  end

  # The swap landed: the answer is the notebook's serving state, and every one of
  # the three names both ids, because the store HAS changed and the safety backup
  # is what undoes it.
  defp landed(:serving, ids), do: {:ok, ids}
  defp landed(:not_serving, ids), do: {:error, {:restored_notebook_not_serving, ids}}
  defp landed(:down, ids), do: {:error, {:restored_notebook_down, ids}}

  # Nothing was overwritten. A notebook that came back serving is told what was
  # wrong with THIS attempt; one that did not is answered as a notebook that did
  # not come back, with no id — the store is as it was, and the person's action
  # is the same whatever the swap would have done.
  defp untouched(:down, _reason, _safety_backup), do: {:error, :notebook_down}
  defp untouched(:not_serving, _reason, _safety_backup), do: {:error, :notebook_not_serving}

  defp untouched(:serving, :backup_unreadable, safety_backup),
    do: {:error, {:backup_unreadable, %{safety_backup: safety_backup}}}

  defp untouched(:serving, :swap_not_started, safety_backup),
    do: {:error, {:restore_not_started, %{safety_backup: safety_backup}}}

  # Remove a stale WAL/SHM. Tolerate absence (`:enoent`), but RAISE on a real
  # error such as EPERM — swallowing it could leave the new database beside an
  # un-removed old WAL, the corruption the swap ordering exists to prevent.
  defp rm_if_present!(path) do
    case File.rm(path) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        raise File.Error, reason: reason, action: "remove stale WAL/SHM", path: path
    end
  end
end
