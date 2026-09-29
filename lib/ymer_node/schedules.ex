defmodule YmerNode.Schedules do
  @moduledoc """
  The node's schedules: standing instructions to run one action of one accepted
  script, with fixed args, on a cron expression in the node's time zone, until
  each one's [*lifetime*](docs/glossary.md#lifetime) ends — and the watches that
  keep references' cache entries current (§ Watches). They are added, listed,
  updated and removed through the `schedules` tool and the CLI, a watch is
  started and stopped through the `references` tool, and all of them are fired
  by `YmerNode.Schedules.Scheduler`.

  The node is a script runner with scheduling flexibility — not a reliable
  scheduler, and not a work engine. A [*firing*](docs/glossary.md#firing)
  starts one run through `YmerNode.Scripts.run/3`, the door an MCP call uses, so
  it meets the same acceptance check, batteries, deadline and isolation; nothing
  routes, chains, retries or catches up. Where a reliable scheduler would have a
  policy, this module has the simplest rule that never runs anything twice or
  without end.

  ```mermaid
  flowchart TD
      Schedules[YmerNode.Schedules]

      subgraph owned
          Schedule[Schedule schema]
          Cron
          Lifetime
          LastRun
          InFlight
          Scheduler
      end

      subgraph external
          Scripts[YmerNode.Scripts]
          Runner[Scripts.Runner]
          Context[Script.Context]
          Cache[References.Cache]
          Sources[References.Sources]
          Repo[(YmerNode.Repo)]
      end

      Scheduler -->|"active/1 each minute, fire/2 per firing"| Schedules
      Schedules --> Schedule
      Schedules -->|"parse, next firing"| Cron
      Schedules -->|"where a lifetime ends"| Lifetime
      Schedules -->|"the last run's fields"| LastRun
      Schedules -->|"a firing's run in flight"| InFlight
      Schedules -->|"check/3 before storing and firing, longest/1"| Runner
      Schedules -->|"run/3 at a firing"| Scripts
      Schedules -->|"the node time zone"| Context
      Schedules -->|"a watch's recipe, and its refresh"| Cache
      Schedules -->|"the declarations a watch's firing reads"| Sources
      Schedules --> Repo
  ```

  ## What add and update refuse

  What can be checked at the keyboard is checked there, rather than at a firing
  nobody watches: the name (`YmerNode.Schedules.Schedule`), the cron expression
  (`YmerNode.Schedules.Cron`), the lifetime (`YmerNode.Schedules.Lifetime`), and —
  through `YmerNode.Scripts.Runner.check/3`, which reads this boot's compile and
  runs no script code — a script that is unknown or not accepted, an action it
  does not serve, and args that action's schema rejects. `update` runs the same
  checks on what it changes. Every firing still meets the runner's own checks,
  because a script can change after its schedule was added: a firing of an action
  the script has since dropped is refused, and the refusal lands on the last run.

  The args are kept on the row and shown by every `list` for as long as the
  schedule lives, and a call's args are open-world: a key the action's schema
  does not name is let through, not refused. So a secret never goes in them — a
  script that needs one declares it, and reads it at run time with
  `YmerNode.Script.Context.secret/2`.

  ## A schedule's life

  ```mermaid
  stateDiagram-v2
      [*] --> Active : add, or watch
      Active --> Active : update, or watch again
      Active --> Expired : its lifetime ends
      Expired --> Active : update with a lifetime, or watch again
      Active --> [*] : remove, unwatch, or its script's or reference's remove
      Expired --> [*] : remove, unwatch, or its script's or reference's remove

      note right of Active
          fires at each firing of its cron
          expression before its end
      end note
  ```

  Two states and nothing else: no pause, no "expires soon". A lifetime given to
  `update` is read as at `add`, from the moment of the update, and that is how a
  schedule is renewed. An `update` without one leaves the end where it stands, so
  adjusting a schedule's cron expression or args never extends its life:
  renewing stays a deliberate act.

  ## Watches

  A **watch** is a reference's own schedule: it keeps that reference's cache
  entry current, refreshing it at a cadence of 5, 15, 30 or 60 minutes for a
  lifetime of 1 to 12 hours. It names no script and no action. Each firing
  looks the reference up, derives its fetch recipe at that moment and runs the
  cache's conditional refresh (`YmerNode.References.Cache.refresh/2`), so a
  watch follows a changed uri, a newly accepted claimant or the web fallback
  without being touched; a firing that finds no script to fetch the reference
  is kept as `refused` and the watch lives on to its end.

  `watch/3` starts one or replaces the one a reference has — cadence and
  lifetime both set afresh, the last run kept — and `unwatch/1` stops it. Its
  name is the node's, `reference-<id>`, and `add` refuses that prefix to anyone
  else. `list` shows a watch among the other schedules, marked with its
  reference, and `remove` stops it; `update` refuses it, because the cadence
  and the lifetime are bounded by the watch and a free cron expression would
  step outside them. The reference's delete takes its watch with it.

  ## A firing

  A firing whose minute the node was not up for is skipped — a laptop asleep at
  07:00 does not run the 07:00 report when it wakes, perhaps off the network the
  report needs. So is a firing while the same schedule's previous run is still in
  flight: per schedule and never per script, so two schedules of one script, or a
  schedule and a manual run, never block each other. Firings due in one minute
  all start in that minute; a host that needs pacing gets it from its throttle. A
  skipped firing leaves no trace.

  A firing's run holds an entry in `YmerNode.Schedules.InFlight` for as long as
  it lasts, keyed by the schedule's row rather than its name, so a schedule
  removed and added again under that name while the old run finishes is not
  skipped for it. That is how the next firing knows to skip, and how an edit of
  the script, refused while the run is in flight, names the schedule holding it
  and the second the run is over by at the latest.

  ## Times

  Every instant an answer carries — the next firing, the lifetime's end, the last
  run's firing — is ISO-8601 in the node's time zone, with its offset, because
  that is the zone a cron expression and an offset-less lifetime are read in:
  `0 7 * * *` reads back as 07:00, and a change of clock shows as a new offset.
  """
  import Ecto.Query, warn: false

  alias YmerNode.References.{Cache, Reference, Sources}
  alias YmerNode.Repo
  alias YmerNode.Schedules.{Cron, InFlight, LastRun, Lifetime, Schedule}
  alias YmerNode.Script.Context
  alias YmerNode.Scripts
  alias YmerNode.Scripts.Runner
  alias YmerNode.Scripts.Script

  @watch_prefix "reference-"

  # A watch's cadence, in minutes, as the cron expression each one fires on.
  @cadences %{5 => "*/5 * * * *", 15 => "*/15 * * * *", 30 => "*/30 * * * *", 60 => "0 * * * *"}

  # ─── Reading ────────────────────────────────────────────────────────

  @doc """
  Every schedule, ordered by name: what runs, when next, until when, and how the
  last run went — the shape `add/1` and `update/2` answer too.

  Each entry carries `name`, `script`, `action` and `args` — for a watch,
  `watch: %{reference: id}` in their place — `cron_expression`,
  `state` (`"active"` or `"expired"`), `ends_at`, `next_firing` — `nil` once
  expired, when the expression comes due no more before the end, when its walk
  gives out, or when the stored expression no longer parses under the running
  code, which leaves the row listed and every other row answered — and
  `last_run`: `nil` before the first run, else `fired_at`, `outcome`, `message`
  and `took_ms`.
  """
  def list do
    now = DateTime.utc_now()

    Schedule
    |> order_by(asc: :name)
    |> preload(:script)
    |> Repo.all()
    |> Enum.map(&entry(&1, now))
  end

  @doc """
  The schedules still inside their lifetime at `at` — what
  `YmerNode.Schedules.Scheduler` reads every minute. Their scripts are not
  loaded: a firing reads its script — or, for a watch, derives its recipe —
  afresh (`fire/2`).
  """
  def active(%DateTime{} = at) do
    at = DateTime.truncate(at, :second)

    Repo.all(from schedule in Schedule, where: schedule.ends_at > ^at)
  end

  # ─── Writing ────────────────────────────────────────────────────────

  @doc """
  Adds a schedule, answered as `list/0` shows it — its end and its next firing
  among the rest, which is what the caller needs next.

  Takes `:name`, `:script`, `:action` and `:cron_expression`, and optionally
  `:args` (none by default) and `:lifetime` (the 90-day ceiling by default).
  """
  def add(%{name: name, script: script, action: action, cron_expression: expression} = attrs)
      when is_binary(name) and is_binary(script) and is_binary(action) and
             is_binary(expression) do
    args = Map.get(attrs, :args, %{})

    with :ok <- check_name(name),
         {:ok, _cron} <- Cron.parse(expression),
         {:ok, ends_at} <-
           Lifetime.ends_at(Map.get(attrs, :lifetime), DateTime.utc_now(), Context.time_zone()),
         {:ok, row} <- Scripts.get(script),
         {:ok, _schema} <- Runner.check(row, action, args) do
      %Schedule{}
      |> Schedule.changeset(%{
        name: name,
        script_id: row.id,
        action: action,
        args: args,
        cron_expression: String.trim(expression),
        ends_at: ends_at
      })
      |> insert(script)
      |> answered(name)
    end
  end

  @doc """
  Changes a schedule's `:cron_expression`, `:args` or `:lifetime` — any of them —
  checking each the way `add/1` does, and keeps its last run.

  A lifetime is read from now, and renews an expired schedule as readily as an
  active one; without one the end stays where it is. The script and the action
  are fixed: another one is another schedule.
  """
  def update(name, changes) when is_binary(name) and is_map(changes) do
    with {:ok, schedule} <- fetch(name),
         :ok <- check_not_watch(schedule),
         {:ok, attrs} <- changed(schedule, changes) do
      schedule
      |> Schedule.changeset(attrs)
      |> Repo.update()
      |> answered(name)
    end
  end

  @doc """
  Starts a watch on a reference, or replaces the one it has — its cadence and
  its lifetime both set afresh from now, its last run kept — answered as
  `list/0` shows it. `cadence_minutes` is one of 5, 15, 30 or 60, and
  `lifetime_hours` one of 1 to 12; anything else is refused by name.
  """
  def watch(%Reference{} = reference, cadence_minutes, lifetime_hours)
      when is_integer(cadence_minutes) and is_integer(lifetime_hours) do
    with {:ok, cron_expression} <- cadence(cadence_minutes),
         {:ok, ends_at} <- watch_end(lifetime_hours) do
      name = @watch_prefix <> Integer.to_string(reference.id)

      (Repo.get_by(Schedule, reference_id: reference.id) || %Schedule{})
      |> Schedule.watch_changeset(%{
        name: name,
        reference_id: reference.id,
        args: %{},
        cron_expression: cron_expression,
        ends_at: ends_at
      })
      |> write_watch(reference)
      |> answered(name)
    end
  end

  # As in `insert/2`: a reference removed after the caller loaded it arrives as
  # the adapter's unnamed foreign-key raise, answered as the not-found it is.
  defp write_watch(changeset, reference) do
    Repo.insert_or_update(changeset)
  rescue
    error in Ecto.ConstraintError -> reference_gone(error, reference, __STACKTRACE__)
  end

  defp reference_gone(%Ecto.ConstraintError{type: :foreign_key}, reference, _stacktrace),
    do: {:error, {:not_found, "no reference #{reference.id}"}}

  defp reference_gone(error, _reference, stacktrace), do: reraise(error, stacktrace)

  @doc "Stops a reference's watch, answering the row that went."
  def unwatch(reference_id) when is_integer(reference_id) do
    case Repo.get_by(Schedule, reference_id: reference_id) do
      nil -> {:error, {:not_found, "reference #{reference_id} has no watch"}}
      %Schedule{name: name} -> remove(name)
    end
  end

  @doc "Removes a schedule, a watch included, answering the row that went."
  def remove(name) when is_binary(name) do
    with {:ok, schedule} <- fetch(name) do
      case Repo.delete_all(from row in Schedule, where: row.id == ^schedule.id) do
        {1, _rows} -> {:ok, schedule}
        {0, _rows} -> {:error, not_found(name)}
      end
    end
  end

  # ─── Firing ─────────────────────────────────────────────────────────

  @doc """
  Fires one schedule for the minute `fired_at` came due: starts its run and keeps
  the last run on the row, answering the outcome — or answers `:skipped` and
  keeps nothing while the schedule's previous run is still in flight.

  Runs in the calling process for as long as the run lasts;
  `YmerNode.Schedules.Scheduler` calls it from a task of its own for each
  firing. The script is read again here, by the row the schedule holds, so the
  firing runs whatever is accepted under that name at this moment; a watch's
  recipe is derived here from its reference, as a read derives it. A firing
  that raises is recorded as an `error` like any failed run.
  """
  def fire(%Schedule{} = schedule, %DateTime{} = fired_at) do
    started = System.monotonic_time(:millisecond)

    case contained(schedule, fn -> prepare(schedule) end) do
      {:ok, run} -> run_once(schedule, run, {fired_at, started})
      {:error, _reason} = refusal -> record(schedule, refusal, {fired_at, started})
    end
  end

  # What a firing runs, checked the way the run will be: the script, its
  # action's schema for the deadline, and the call itself.
  defp prepare(%Schedule{reference_id: nil, script_id: id, action: action, args: args}) do
    case Repo.get(Script, id) do
      nil ->
        {:error, {:not_found, "the script this schedule runs is gone"}}

      %Script{} = script ->
        with {:ok, schema} <- Runner.check(script, action, args),
             do: {:ok, run(script, schema, fn -> Scripts.run(script.name, action, args) end)}
    end
  end

  # A watch names no script: its firing derives the recipe at this moment, as a
  # read does, and runs the cache's refresh — one read of the seam for both.
  defp prepare(%Schedule{reference_id: reference_id}) do
    declarations = Sources.declarations()

    with {:ok, reference} <- watched(reference_id),
         {:ok, recipe} <- recipe(reference, declarations),
         {:ok, script} <- Scripts.get(recipe.script),
         {:ok, schema} <- Runner.check(script, recipe.action, %{"url" => reference.uri}) do
      {:ok, run(script, schema, fn -> Cache.refresh(reference, declarations) end)}
    end
  end

  # A reference no script fetches any more keeps no entry, as a read or a
  # refresh of it would leave none.
  defp recipe(reference, declarations) do
    with {:error, _no_recipe} = refusal <- Cache.recipe(reference, declarations) do
      Cache.drop(reference.id)
      refusal
    end
  end

  defp run(script, schema, call), do: %{script: script.name, schema: schema, call: call}

  defp watched(reference_id) do
    case Repo.get(Reference, reference_id) do
      nil -> {:error, {:not_found, "the reference this watch keeps is gone"}}
      %Reference{} = reference -> {:ok, reference}
    end
  end

  # The entry is taken before the run and dropped after it, whatever happens;
  # the process registry drops it anyway if this process dies, so a killed
  # firing never leaves its schedule skipping for ever.
  defp run_once(schedule, run, timing) do
    until = latest_end(Runner.longest(run.schema))

    case InFlight.register(schedule.id, schedule.name, run.script, until) do
      :ok -> run_registered(schedule, run.call, timing)
      :in_flight -> :skipped
    end
  end

  # The entry goes as the run ends, before the record is written: a refusal
  # read while the record waits on the database names no finished run. The
  # runner contains a script's own raise; what a watch's refresh does around the
  # run — the database, the cache directory — is contained here, so every
  # firing records an outcome.
  defp run_registered(schedule, call, timing) do
    result =
      try do
        contained(schedule, call)
      after
        InFlight.unregister(schedule.id)
      end

    record(schedule, result, timing)
  end

  # A raise answered as the failed run it is — around the run, and before it,
  # where a watch looks up its reference and derives its recipe.
  defp contained(schedule, fun) do
    fun.()
  rescue
    exception ->
      {:error, {:script_raised, "#{schedule.name}: #{Exception.message(exception)}"}}
  catch
    kind, reason ->
      {:error, {:script_raised, "#{schedule.name}: #{Exception.format_banner(kind, reason)}"}}
  end

  # The run's deadline from now, rounded up to the whole second: a refusal
  # promises the run is over by then, so no part of a second is rounded away.
  defp latest_end(longest_ms) do
    DateTime.utc_now()
    |> DateTime.add(longest_ms, :millisecond)
    |> DateTime.add(999_999, :microsecond)
    |> DateTime.truncate(:second)
  end

  # A schedule removed while its run was in flight updates no row, and that is
  # the whole of what happens to its last run.
  defp record(schedule, result, {fired_at, started}) do
    took_ms = System.monotonic_time(:millisecond) - started
    attrs = LastRun.attrs(result, fired_at, took_ms)

    Repo.update_all(from(row in Schedule, where: row.id == ^schedule.id), set: Map.to_list(attrs))
    attrs.last_outcome
  end

  # ─── Checks ─────────────────────────────────────────────────────────

  defp check_name(name) do
    cond do
      not Schedule.valid_name?(name) ->
        {:error,
         {:invalid_name,
          "#{name} is not a schedule name — lowercase letters, digits, - and _, " <>
            "starting with a letter or digit"}}

      String.starts_with?(name, @watch_prefix) ->
        {:error,
         {:reserved_name,
          "#{name} is a watch's name — names starting #{@watch_prefix} belong to the " <>
            "watches the references tool starts"}}

      Repo.exists?(from schedule in Schedule, where: schedule.name == ^name) ->
        {:error, taken(name)}

      true ->
        :ok
    end
  end

  defp check_not_watch(%Schedule{reference_id: nil}), do: :ok

  defp check_not_watch(%Schedule{name: name, reference_id: reference_id}) do
    {:error,
     {:watch,
      "#{name} is the watch on reference #{reference_id} — its cadence and lifetime " <>
        "change through references watch, and references unwatch stops it"}}
  end

  defp cadence(minutes) do
    case Map.fetch(@cadences, minutes) do
      {:ok, cron_expression} ->
        {:ok, cron_expression}

      :error ->
        {:error,
         {:invalid_cadence, "every #{minutes} minutes is not a watch's cadence — 5, 15, 30 or 60"}}
    end
  end

  defp watch_end(hours) when hours in 1..12,
    do: Lifetime.ends_at("PT#{hours}H", DateTime.utc_now(), Context.time_zone())

  defp watch_end(hours),
    do: {:error, {:invalid_lifetime, "#{hours} hours is not a watch's lifetime — 1 to 12"}}

  defp changed(schedule, changes) do
    with {:ok, cron_expression} <- changed_cron_expression(changes),
         {:ok, args} <- changed_args(schedule, changes),
         {:ok, ends_at} <- changed_end(changes) do
      {:ok, cron_expression |> Map.merge(args) |> Map.merge(ends_at)}
    end
  end

  defp changed_cron_expression(%{cron_expression: expression}) when is_binary(expression) do
    with {:ok, _cron} <- Cron.parse(expression),
         do: {:ok, %{cron_expression: String.trim(expression)}}
  end

  defp changed_cron_expression(_changes), do: {:ok, %{}}

  defp changed_args(schedule, %{args: args}) when is_map(args) do
    with {:ok, _schema} <- Runner.check(schedule.script, schedule.action, args),
         do: {:ok, %{args: args}}
  end

  defp changed_args(_schedule, _changes), do: {:ok, %{}}

  defp changed_end(%{lifetime: lifetime}) when is_binary(lifetime) do
    with {:ok, ends_at} <- Lifetime.ends_at(lifetime, DateTime.utc_now(), Context.time_zone()),
         do: {:ok, %{ends_at: ends_at}}
  end

  defp changed_end(_changes), do: {:ok, %{}}

  defp fetch(name) do
    case Repo.one(from schedule in Schedule, where: schedule.name == ^name, preload: :script) do
      nil -> {:error, not_found(name)}
      %Schedule{} = schedule -> {:ok, schedule}
    end
  end

  # SQLite names no constraint when a foreign key fails, so the changeset's
  # `foreign_key_constraint/2` cannot turn a script removed between the look in
  # `add/1` and this insert into an error; the adapter raises instead, and the
  # answer is the not-found the look gives.
  defp insert(changeset, script) do
    Repo.insert(changeset)
  rescue
    error in Ecto.ConstraintError -> script_gone(error, script, __STACKTRACE__)
  end

  defp script_gone(%Ecto.ConstraintError{type: :foreign_key}, script, _stacktrace),
    do: {:error, {:not_found, "no script named #{script}"}}

  defp script_gone(error, _script, stacktrace), do: reraise(error, stacktrace)

  # The unique index is the one check a concurrent add can get past the look in
  # `check_name/1`; its refusal is the same one the look gives. Any other
  # changeset error goes back whole, for each door to render.
  defp answered({:ok, schedule}, _name) do
    {:ok, schedule |> Repo.preload(:script) |> entry(DateTime.utc_now())}
  end

  defp answered({:error, %Ecto.Changeset{} = changeset}, name) do
    if Keyword.has_key?(changeset.errors, :name),
      do: {:error, taken(name)},
      else: {:error, changeset}
  end

  defp answered({:error, {:not_found, _detail}} = refusal, _name), do: refusal

  defp taken(name) do
    {:name_taken,
     "a schedule named #{name} already exists — update it, or remove it and add it again"}
  end

  defp not_found(name), do: {:not_found, "no schedule named #{name}"}

  # ─── Shaping a read ─────────────────────────────────────────────────

  defp entry(%Schedule{} = schedule, now) do
    zone = Context.time_zone()
    expired? = DateTime.compare(schedule.ends_at, now) != :gt

    schedule
    |> subject()
    |> Map.merge(%{
      name: schedule.name,
      cron_expression: schedule.cron_expression,
      state: if(expired?, do: "expired", else: "active"),
      ends_at: render(schedule.ends_at, zone),
      next_firing: if(expired?, do: nil, else: next_firing(schedule, now, zone)),
      last_run: last_run(schedule, zone)
    })
  end

  # What a schedule runs: a script's action with its args, or — for a watch —
  # the reference it keeps.
  defp subject(%Schedule{reference_id: nil} = schedule),
    do: %{script: schedule.script.name, action: schedule.action, args: schedule.args}

  defp subject(%Schedule{reference_id: reference_id}), do: %{watch: %{reference: reference_id}}

  # A stored expression the running code no longer parses — a stricter rule
  # than the one that stored it — answers no next firing, as the scheduler
  # treats it, rather than failing the whole read.
  defp next_firing(schedule, now, zone) do
    case Cron.parse(schedule.cron_expression) do
      {:ok, cron} -> next_before_end(cron, schedule.ends_at, DateTime.shift_zone!(now, zone))
      {:error, _refused} -> nil
    end
  end

  defp next_before_end(cron, ends_at, local) do
    case Cron.next_firing(cron, local) do
      :none -> nil
      next -> if DateTime.compare(next, ends_at) == :lt, do: render(next, local.time_zone)
    end
  end

  defp last_run(%Schedule{last_fired_at: nil}, _zone), do: nil

  defp last_run(%Schedule{} = schedule, zone) do
    %{
      fired_at: render(schedule.last_fired_at, zone),
      outcome: schedule.last_outcome,
      message: schedule.last_message,
      took_ms: schedule.last_run_ms
    }
  end

  defp render(instant, zone) do
    instant |> DateTime.shift_zone!(zone) |> DateTime.to_iso8601()
  end
end
