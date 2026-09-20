defmodule YmerNode.Notebook do
  @moduledoc """
  The notebook — `notebook.db`, a separate, portable SQLite store of user- and
  LLM-governed memories, working and long-term: agent-defined schema, open SQL,
  embeddings, backup and restore. Potentially precious (tutoring records,
  curated knowledge); the node's obligation is durability — governance stays with
  the user and the LLM. This module is its raw-SQL surface (via
  `YmerNode.Notebook.Repo`).

  Thin by design: the agent writes SQL; this module runs it. The only behaviour
  beyond pass-through is the safety model and a `_meta` description layer.

  ## Down, and serving

  Two different facts answer "can the notebook take my statement now", and this
  module reports both rather than collapsing them. **Down** is a fact of the
  process: the repo does not resolve — its name is not registered, or it is
  registered and Ecto has not finished starting it, a window of microseconds —
  so nothing can reach the store at all. **Serving** is a fact of the store: a
  statement runs now.

  A notebook serves when a statement runs now. The node answers serving from what
  the pool itself said — a failure it holds, or one query after a restart — never
  from process registration, which is the other fact, down. The two come apart:
  a repo restarted onto a store it cannot open is registered and not serving, and
  reporting it as either up or down would be a lie the caller acts on.

  Every action reaches the repo through `ensure_meta!/0`, so every action runs
  inside `with_notebook/2`. Its pre-check is
  `YmerNode.Notebook.Repo.running?/0` — a microsecond structural read, the name
  and Ecto's own record of the repo behind it; its catch re-reads that, because
  the repo can stop between the check and the query. Serving is never probed
  ahead of an ordinary call. It is read only where a failure has already put the
  evidence in hand, through `YmerNode.Notebook.Repo.not_serving?/1`, which is
  why the happy path costs nothing.

  The classification, whole, at the pre-check and again in the catch:

    * the repo resolves and the call succeeded — served, and the value goes back
      untouched.
    * resolves, and the pool could not provide a connection —
      `{:error, :notebook_not_serving}`. The node cannot open the store; the
      causes left are permissions, disk faults and an edit under a running node,
      and a wait fixes none of them, so the answer carries no retry advice. The
      node does not wait either: the pool's own reconnect backoff runs from one
      second toward thirty, longer than an honest answer.
    * does not resolve, with the lock held for a **restore** —
      `{:error, :operation_in_progress}`, at once. Only a restore stops the repo,
      so that window is expected and lasts the file swap; it is never waited on.
    * does not resolve, anything else — a bounded wait, because a supervised restart
      is microseconds and answering inside one would be a terminal instruction for
      a condition already resolved. A capture never stops the repo, so a `:backup`
      hold beside a stopped repo is a crash rather than a window, and an
      unreachable lock says nothing about the repo; both wait. If the repo comes
      back: at the pre-check nothing has run, so the body simply runs; in the catch
      a `:read` body runs again, and a `:write` body does not —
      `{:error, :notebook_restarted}`, whose instruction is to check whether the
      statement landed, since it may already have committed and this store cannot
      be rebuilt.
    * still does not resolve when the wait ends — `{:error, :notebook_down}`,
      the stuck state, whose message asks for the one thing that helps, a node
      restart.
    * resolves, and a fault that is none of the above — back to the caller with
      its original kind and stacktrace, so a genuine fault is never swallowed.

  One residual rides that last line, named rather than closed. The repo is
  resolved *after* the failure rather than while it happens, so a repo that
  stopped and came back inside a single call — a supervised restart is
  microseconds — resolves again by the time the catch reads it, and the failure
  the stopped repo caused is classified as a fault of the caller's own statement
  and re-raised.
  What the repo raises when it does not resolve is a `RuntimeError`, or — inside
  the start window — an `ArgumentError` out of the registry; each carries a
  message and nothing structural to match, so recognising either would mean
  reading a dependency's text — the one thing this classification does not do.
  The cost is one raw exception in front of a caller whose call happened to race
  a restart, and it closes itself: the next call finds the notebook serving.

  The classification binds to **structural** state throughout: process
  registration and Ecto's own record of the repo, the lock's held op, and — for
  serving — an exception's documented type and `reason` field. Matching the text
  of a dependency's message stays forbidden; that text is free to change, and a
  check that read it would keep passing until the day the wording moved.

  ## Read-only enforcement (non-obvious — do not remove)

  `query/1` runs the statement inside `YmerNode.Notebook.Repo.transaction/1` and ALWAYS
  rolls back. A `SELECT`'s rows ride out through the rollback value; any write a
  crafted statement performs is discarded. This is the hard guarantee — the
  leading-keyword check is only a friendly router, and is leaky on its own because
  `WITH … DELETE` is a valid write that starts with `WITH`. `EXPLAIN` reads also
  route here; `PRAGMA` is rejected (some pragmas are connection-level writes a
  rollback won't undo — use the `tables`/`schema` actions for introspection).

  `execute/1` blocks `ATTACH`/`DETACH`. The store is the only database worth
  protecting, and the node database sits beside it — but ATTACH reaches any
  SQLite file the process can open, not merely those two, so a prompt-injected
  agent must not have the verb at all. `VACUUM INTO` is blocked
  on the same ground — it writes a full copy of the database to any path the
  process can write (bare `VACUUM` compaction stays legal). The `execute` path has NO
  rollback backstop, so its guard is load-bearing on its own. The classifier
  strips ALL SQL comments and any leading whitespace/`(`/`;` and case-folds, so
  `;ATTACH …`, `(ATTACH …)`, and an inline `attach/**/database …` cannot slip
  past. Multi-statement tails are inert because
  `YmerNode.Notebook.Repo.query/1` prepares only the first statement (exqlite `Sqlite3.prepare`)
  — this MUST NOT be swapped for `Exqlite.Sqlite3.execute/2`, which would run the tail.

  ## Result shaping (exqlite command heuristic — do not trust it)

  `ecto_sqlite3` builds the query without a `:command`, so exqlite classifies a
  statement by a case-sensitive substring match for `INSERT`/`UPDATE`/`DELETE`. That
  drops the `columns` of a SELECT whose text contains such a substring, and reports a
  wrong/stale `changes()` count for lowercase DML and substring-bearing DDL. So
  `query/1` passes `command: :select` to keep columns, and `execute/1` derives
  `affected_rows` from `SELECT changes()` on the same connection
  (`YmerNode.Notebook.Repo.checkout/2`) keyed on our own leading-keyword classifier.

  ## The vector layer

  `notebook.db` loads sqlite-vec, so the agent can keep `vec0` virtual tables
  beside ordinary ones and run KNN search through `query/1`. The usage discipline
  that comes with it — the INTEGER-PRIMARY-KEY join rule, the delete-from-both
  rule, and sqlite-vec's requirement that MATCH+LIMIT run in its own
  subquery/CTE — lives in `YmerNode.Mcp.Tools.Notebook.Schemas`' action notes, written
  for the agent that composes the SQL; `help {tool: "notebook"}` returns them.

  ## `_meta`

  SQLite has no column comments, so `ensure_meta!/0` keeps a `_meta(target,
  description, …)` table (Datasette-style `table:name` / `column:table.col` keys)
  that `tables/0` and `table_schema/1` join against. It is created idempotently at
  the start of each call (cheap; a no-op once present) BEFORE the query rollback
  transaction, so a cold `query` cannot roll its creation away.
  """
  alias YmerNode.Notebook.Backup.Lock
  alias YmerNode.Notebook.Repo

  @read_only_leads ~w(SELECT WITH EXPLAIN)
  @blocked_leads ~w(ATTACH DETACH)
  @dml_leads ~w(INSERT UPDATE DELETE)

  @meta_ddl """
  CREATE TABLE IF NOT EXISTS _meta (
    target      TEXT NOT NULL PRIMARY KEY,
    description TEXT,
    created_at  TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at  TEXT NOT NULL DEFAULT (datetime('now'))
  )
  """

  @user_tables_sql """
  SELECT name, sql FROM sqlite_master
  WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name <> '_meta'
  ORDER BY name
  """

  @doc """
  Runs a single DDL/DML statement (no result rows). Rejects `ATTACH`/`DETACH`,
  and `VACUUM INTO` while allowing bare `VACUUM`.
  Returns `{:ok, %{affected_rows: n}}` or `{:error, reason}`.

  `affected_rows` is the exact `SELECT changes()` count when the statement's leading
  keyword is `INSERT`/`UPDATE`/`DELETE`, and `0` for everything else — DDL, and the
  rare CTE-led `WITH … DELETE` write, reported conservatively as 0. It is derived from
  our own comment-stripped, case-folded leading-keyword classifier plus
  `changes()` on the
  same connection, NOT from exqlite's result, whose command classification is an
  unreliable case-sensitive substring match.
  """
  def execute(sql) when is_binary(sql), do: with_notebook(:write, fn -> do_execute(sql) end)

  @doc """
  Runs a read-only `SELECT`/`WITH`/`EXPLAIN` statement inside an always-rolled-back
  transaction. Returns `{:ok, %{columns: [...], rows: [...]}}` or `{:error, reason}`
  (`:not_read_only` if the statement is not a read — `PRAGMA` is rejected; use the
  `tables`/`schema` introspection actions instead). Columns are recovered via
  `command: :select` regardless of exqlite's command heuristic.
  """
  def query(sql) when is_binary(sql), do: with_notebook(:read, fn -> do_query(sql) end)

  @doc """
  Lists user tables (excludes `_meta`, `sqlite_*` internals, and sqlite-vec shadow
  tables). Each entry: `%{name, virtual, row_count, description}`. Virtual (`vec0`)
  tables report `row_count: nil`. Shadow tables are detected by name prefix
  `"<virtual_table>_"` — keep companion tables outside that prefix (the documented
  pattern names them `confluence_pages` next to `vec_confluence_pages`).

  Answers `{:error, reason}` while the notebook is down or cannot open its store.
  That is the one return here that is not a list, so match it before treating the
  answer as one.
  """
  def tables, do: with_notebook(:read, fn -> do_tables() end)

  @doc """
  Full schema for one table: `%{table, virtual, description, columns, indexes}`.
  Regular tables use `PRAGMA table_info`/`index_list`; `vec0` virtual tables parse
  their `CREATE VIRTUAL TABLE … vec0(…)` DDL. Returns `{:error, :table_not_found}`
  if the table does not exist.
  """
  def table_schema(table) when is_binary(table),
    do: with_notebook(:read, fn -> do_table_schema(table) end)

  @doc """
  Runs `fun` and answers a notebook that cannot take it instead of raising at it.

  `body` is what the caller is doing, not what the guard should do with it:
  `:read` for the three actions that only read, `:write` for `execute/1`. The
  guard owns the consequence — only a read may be run a second time, because a
  write's statement may already have committed before the failure reached here,
  and this is the one store the node cannot rebuild.

  Every action above reaches the repo, so every action runs inside this guard. The
  pre-check answers the ordinary stopped case without raising at all; the catch
  covers the race where the repo stops between the check and the query, and both
  classify from structural state rather than from the exception's text, which
  belongs to a dependency. Anything caught while the repo is serving goes back
  exactly as it arrived — kind, value and stacktrace — so a genuine fault is never
  swallowed; the moduledoc names the residual that rides that rule, a failure
  raised while the repo was gone and read once the repo is back. The moduledoc's
  "Down, and serving" section owns the whole classification and what each answer
  means.

  Public ONLY so both halves of that catch are directly testable: the four actions
  hand it a fixed body, so a test working through them can neither make one raise
  while the repo stays up nor stop the repo from inside one. No MCP exposure.
  """
  def with_notebook(body, fun) when body in [:read, :write] and is_function(fun, 0) do
    if Repo.running?(), do: answered(fun.()), else: stopped(fun)
  catch
    kind, reason -> caught(kind, reason, body, fun, __STACKTRACE__)
  end

  # A pool that stops serving between `ensure_meta!/0` and the statement RETURNS
  # its error rather than raising it, and that tuple would otherwise reach the
  # caller as an inspected dependency struct. Reading what came back is not a
  # probe: the evidence is already in hand, which is the only way serving is ever
  # read here.
  defp answered({:error, reason} = answer) do
    if Repo.not_serving?(reason), do: {:error, :notebook_not_serving}, else: answer
  end

  defp answered(answer), do: answer

  # The pre-check. Nothing has run yet, so a repo that comes back inside the
  # bounded wait simply gets the call it was always going to get — both kinds of
  # body, because neither has done anything to repeat. The wait is the repo's
  # own, `YmerNode.Notebook.Repo.await_running/0`: it is what turns a supervised
  # restart into a served call, and its budget lives with the read it polls.
  defp stopped(fun) do
    cond do
      restore_window?() -> {:error, :operation_in_progress}
      Repo.await_running() -> answered(fun.())
      true -> {:error, :notebook_down}
    end
  end

  defp caught(kind, reason, body, fun, stacktrace) do
    if Repo.running?(),
      do: serving_fault(kind, reason, stacktrace),
      else: restarted(body, fun)
  end

  # The repo resolves, so it did not go away: either the pool could not provide a
  # connection — resolving and not serving — or this is a fault of the caller's
  # own statement, which goes back untouched. The repo is resolved AFTER the
  # failure, so a repo that stopped and came back inside the same call lands here
  # too and its lookup failure is re-raised; the moduledoc names that residual and
  # why nothing structural tells it apart.
  defp serving_fault(kind, reason, stacktrace) do
    if Repo.not_serving?(reason),
      do: {:error, :notebook_not_serving},
      else: :erlang.raise(kind, reason, stacktrace)
  end

  # The repo does not resolve, and the body HAS run. Only a restore stops the repo, so a
  # `:restore` hold is the one window that is expected and lasts the swap — it is
  # answered at once and never waited on. Everything else takes the bounded wait,
  # which is what tells a self-healing crash from a stuck notebook.
  defp restarted(body, fun) do
    cond do
      restore_window?() -> {:error, :operation_in_progress}
      not Repo.await_running() -> {:error, :notebook_down}
      body == :read -> retry_read(fun)
      true -> {:error, :notebook_restarted}
    end
  end

  # The retry runs inside a try of its own. This function is reached from
  # `with_notebook/2`'s catch clause, which sits OUTSIDE its own try, so a second
  # failure here would escape as a raw exception or exit rather than the answer
  # this guard exists to produce — and the MCP framework rescues exceptions, not
  # exits. It never retries twice: one restart window is one retry.
  defp retry_read(fun) do
    answered(fun.())
  catch
    kind, reason -> classify_retry(kind, reason, __STACKTRACE__)
  end

  # The retry's own classification, and it reads the lock for the same reason the
  # two above it do: a retry can land in a restore's window, which is the one
  # stopped state that closes on its own. Whether the repo resolves is tested
  # first here, where it is not in `stopped/1` and `restarted/2` — both of those
  # are only reached with the repo already unresolvable, while this one is reached in either state,
  # and a held `:restore` beside a repo that resolves is the restore's pre-swap
  # stretch, where a failure is the caller's own and must not be answered as a
  # window.
  defp classify_retry(kind, reason, stacktrace) do
    cond do
      not Repo.running?() and restore_window?() -> {:error, :operation_in_progress}
      not Repo.running?() -> {:error, :notebook_down}
      Repo.not_serving?(reason) -> {:error, :notebook_not_serving}
      true -> :erlang.raise(kind, reason, stacktrace)
    end
  end

  # `YmerNode.Notebook.Backup.Lock.current/0` contains its own exits, so this read
  # cannot raise — which matters because both callers reach it from the catch
  # clause. It is not free, though: against a lock that is alive and not
  # answering, the read blocks for the Lock's call timeout before answering
  # `:unreachable`, the same cost `Backup`'s `await_lock/1` names — accepted here
  # because a wedged lock has no known trigger. An unreachable lock says nothing
  # about the repo and is not this window; it takes the bounded wait with
  # everything else.
  defp restore_window?, do: Lock.current() == {:busy, :restore}

  # Idempotently ensures the `_meta` description table exists. Private: every
  # caller is an action body above, which reaches it from inside the guard, so it
  # never has to answer for a stopped repo itself.
  defp ensure_meta! do
    {:ok, _} = Repo.query(@meta_ddl)
    :ok
  end

  # The lead is classified ONCE here and threaded down. The comment-stripped text
  # and its upcased first keyword are one fact about the statement, and deriving
  # that fact three times is three chances for the routing checks to disagree
  # about what they are routing. What runs is still the raw `sql`: the classifier's
  # input is what is rebound here, never the statement.
  defp do_execute(sql) do
    ensure_meta!()
    stripped = strip_comments(sql)
    lead = first_keyword(stripped)

    cond do
      # Empty lead = the statement is only comments/whitespace/`;` (e.g. an
      # unterminated `/* ATTACH …` that SQLite reads as a comment-to-EOF no-op). SQLite
      # itself treats such input as success-no-op, but exqlite 0.37.0's prepare returns
      # `:invalid_statement` and its bind_params/3 has no clause for it, raising a
      # TryClauseError that CRASHES the pooled connection — so we short-circuit to the
      # inert no-op before reaching exqlite. Nothing runs, so nothing can attach.
      lead == "" -> {:ok, %{affected_rows: 0}}
      lead in @blocked_leads -> {:error, :blocked_statement}
      vacuum_into?(lead, stripped) -> {:error, :blocked_vacuum_into}
      true -> run_write(sql, lead)
    end
  end

  defp do_query(sql) do
    ensure_meta!()

    if leading_keyword(sql) in @read_only_leads do
      run_read_only(sql)
    else
      {:error, :not_read_only}
    end
  end

  defp do_tables do
    ensure_meta!()
    {:ok, %{rows: rows}} = Repo.query(@user_tables_sql)

    virtual_names = for [name, sql] <- rows, virtual_ddl?(sql), do: name
    descriptions = meta_table_descriptions()

    for [name, sql] <- rows, not shadow?(name, virtual_names) do
      virtual = virtual_ddl?(sql)

      %{
        name: name,
        virtual: virtual,
        row_count: if(virtual, do: nil, else: count_rows(name)),
        description: Map.get(descriptions, "table:#{name}")
      }
    end
  end

  defp do_table_schema(table) do
    ensure_meta!()

    case Repo.query("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?1", [
           table
         ]) do
      {:ok, %{rows: [[ddl]]}} ->
        descriptions = meta_table_descriptions()

        base = %{
          table: table,
          virtual: virtual_ddl?(ddl),
          description: Map.get(descriptions, "table:#{table}")
        }

        if virtual_ddl?(ddl) do
          {:ok, Map.merge(base, %{columns: parse_vec0_columns(ddl), indexes: []})}
        else
          {:ok,
           Map.merge(base, %{
             columns: regular_columns(table, descriptions),
             indexes: regular_indexes(table)
           })}
        end

      {:ok, %{rows: []}} ->
        {:error, :table_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # affected_rows must not come from exqlite's num_rows (its command classification is
  # a case-sensitive substring guess). We run the write and read
  # `SELECT changes()` on the SAME connection (checkout/2 — the pool has many in prod),
  # counting only a genuine INSERT/UPDATE/DELETE lead; DDL and everything else report 0.
  # ensure_meta!/0 already ran OUTSIDE this checkout, so its DDL cannot perturb changes().
  # Executing raw agent-authored SQL against the user/LLM-governed notebook DB is
  # this module's purpose (see @moduledoc) — not an injection surface.
  defp run_write(sql, lead) do
    Repo.checkout(fn ->
      case Repo.query(sql) do
        {:ok, _result} -> {:ok, %{affected_rows: write_count(lead)}}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp write_count(lead) do
    if lead in @dml_leads do
      {:ok, %{rows: [[n]]}} = Repo.query("SELECT changes()")
      n
    else
      0
    end
  end

  defp virtual_ddl?(nil), do: false
  defp virtual_ddl?(sql), do: String.match?(sql, ~r/create\s+virtual\s+table/i)

  defp shadow?(name, virtual_names) do
    Enum.any?(virtual_names, fn v -> v != name and String.starts_with?(name, v <> "_") end)
  end

  defp count_rows(name) do
    {:ok, %{rows: [[n]]}} = Repo.query(~s|SELECT count(*) FROM #{quote_ident(name)}|)
    n
  end

  defp meta_table_descriptions do
    {:ok, %{rows: rows}} = Repo.query("SELECT target, description FROM _meta")
    Map.new(rows, fn [target, description] -> {target, description} end)
  end

  defp regular_columns(table, descriptions) do
    {:ok, %{rows: rows}} = Repo.query(~s|PRAGMA table_info(#{quote_ident(table)})|)

    for [_cid, name, type, notnull, dflt, pk] <- rows do
      %{
        name: name,
        type: type,
        not_null: notnull == 1,
        default: dflt,
        pk: pk > 0,
        description: Map.get(descriptions, "column:#{table}.#{name}")
      }
    end
  end

  defp regular_indexes(table) do
    {:ok, %{rows: rows}} = Repo.query(~s|PRAGMA index_list(#{quote_ident(table)})|)

    for [_seq, name, unique | _rest] <- rows do
      {:ok, %{rows: cols}} = Repo.query(~s|PRAGMA index_info(#{quote_ident(name)})|)

      %{
        name: name,
        unique: unique == 1,
        columns: Enum.map(cols, fn [_seqno, _cid, col] -> col end)
      }
    end
  end

  # Extracts column defs from `... USING vec0(embedding float[768], +id text)`.
  # Auxiliary (`+`) and partition columns keep their declared type text as-is.
  defp parse_vec0_columns(ddl) do
    case Regex.run(~r/vec0\s*\((.*)\)/is, ddl) do
      [_, inner] ->
        inner
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(&parse_vec0_column/1)

      _ ->
        []
    end
  end

  defp parse_vec0_column(col) do
    case String.split(String.trim_leading(col, "+"), ~r/\s+/, parts: 2) do
      [name, type] -> %{name: name, type: type}
      [name] -> %{name: name, type: nil}
    end
  end

  # PRAGMA/COUNT cannot be parameterised, so the identifier is interpolated. Names
  # come from sqlite_master (already proven to exist) or the validated `table`
  # param; double-quote and escape embedded quotes to neutralise injection.
  defp quote_ident(name), do: ~s|"| <> String.replace(name, ~s|"|, ~s|""|) <> ~s|"|

  # `Repo.rollback/1` makes `Repo.transaction/1` return `{:error, rolled_back_value}`.
  # We always roll back, tagging the inner result so the caller can tell an
  # intentional rollback-carrying-rows from a real SQL error (both surface here as
  # the transaction's `{:error, _}`). The read passes `command: :select` so exqlite
  # does not misclassify a SELECT containing an uppercase INSERT/UPDATE/DELETE substring
  # as DML and drop its columns. If a future Ecto build does not
  # forward this opt, the column-recovery tests fail RED — recover columns via the fallback
  # (detect command != nil and rows != [] and columns == [], or prepare the statement and
  # read columns directly) rather than trusting the result.
  # Raw notebook SQL by design — same rationale as run_write/2.
  defp run_read_only(sql) do
    outcome =
      Repo.transaction(fn ->
        case Repo.query(sql, [], command: :select) do
          {:ok, result} -> Repo.rollback({:ok, result})
          {:error, reason} -> Repo.rollback({:error, reason})
        end
      end)

    case outcome do
      {:error, {:ok, %{columns: cols, rows: rows}}} ->
        {:ok, %{columns: cols || [], rows: rows || []}}

      {:error, {:error, reason}} ->
        {:error, reason}
    end
  end

  # First SQL keyword, upcased — with ALL comments removed and leading whitespace,
  # parens, and semicolons stripped, so `/* x */ attach …`, `;ATTACH …`,
  # `(SELECT …)`, and `attach/**/database …` are all classified by their real leading
  # keyword. Used only to ROUTE/BLOCK; the statement that actually runs is never
  # rewritten, which is why over-stripping is safe — it can only expose more leading
  # structure, never hide a blocked lead.
  defp leading_keyword(sql) do
    sql
    |> strip_comments()
    |> first_keyword()
  end

  # The upcased first keyword of text whose comments are already gone. Split out
  # of `leading_keyword/1` so a caller that has stripped once — and needs the
  # stripped text for itself — can classify without stripping a second time.
  defp first_keyword(stripped) do
    stripped
    |> first_token()
    |> String.upcase()
  end

  # Removes `--` line comments and `/* … */` block comments, including an inline
  # `attach/**/database` and an unterminated `/* …` to EOF (which SQLite treats as a
  # comment). Comment markers inside string literals cannot precede the leading
  # keyword, so this is safe for classification.
  #
  # ONE left-to-right alternation, not three ordered passes: whichever comment
  # opens first wins, which is how SQLite's own tokenizer reads the text. Three
  # passes cannot express that — running the block rules first lets an unpaired
  # `/*` *inside* a `--` comment ("-- see notes/*.sql") swallow the statement that
  # follows it, so `execute/1` short-circuits on an empty lead and reports
  # `{:ok, %{affected_rows: 0}}` for a write that never ran; running the line rule
  # first breaks the mirror case, a `--` inside a `/* … */` block. The order
  # inside the alternation is load-bearing too: the terminated block pattern must
  # precede the to-EOF one, or every `/* … */` is read as unterminated.
  defp strip_comments(sql) do
    String.replace(sql, ~r{--[^\n]*|/\*.*?\*/|/\*.*\z}s, " ")
  end

  # First token after stripping any leading whitespace, `(`, or `;` — so a
  # parenthesised or `;`-led statement yields its real keyword instead of "".
  # `String.split/3` always returns a non-empty list, so `hd/1` is total.
  defp first_token(str) do
    str
    |> String.replace(~r/\A[\s(;]+/, "")
    |> String.split(~r/[\s(;]/, parts: 2)
    |> hd()
  end

  # `VACUUM` compacts in place and is legal; `VACUUM [schema] INTO 'file'` writes
  # a full copy of the database to any path the process can write — the same
  # reach-outside-this-file capability the ATTACH block denies, and a copy planted
  # in the backups directory under a member-shaped name even becomes restorable.
  # Per statement, INTO appears nowhere else in VACUUM's grammar — but the scan
  # runs over the WHOLE comment-stripped input, deliberately fail-closed: a
  # `VACUUM; INSERT INTO …` is refused although its tail is inert (only the first
  # statement is ever prepared), and the error message tells the caller to send
  # the VACUUM alone. The no-bypass property also rests on the vendored exqlite
  # build REJECTING unknown schema names (no SQLITE_BUG_COMPATIBLE_20160819): a
  # comment-shaped schema name cannot hide INTO from SQLite while hiding it from
  # us. A system sqlite built WITH that bug-compat flag ignores the bogus schema
  # name and writes the file — re-verify this block if the driver or its build
  # flags ever change.
  defp vacuum_into?(lead, stripped) do
    lead == "VACUUM" and String.match?(stripped, ~r/\bINTO\b/i)
  end
end
