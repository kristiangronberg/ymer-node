defmodule YmerNode.Schedules do
  @moduledoc """
  The node's schedules: standing instructions to run one action of one accepted
  script, with fixed args, on a cron expression in the node's time zone, until
  each one's [*lifetime*](docs/glossary.md#lifetime) ends. They are added,
  listed, updated and removed through the `schedules` tool and the CLI, and
  fired by `YmerNode.Schedules.Scheduler`.

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
      [*] --> Active : add
      Active --> Active : update
      Active --> Expired : its lifetime ends
      Expired --> Active : update with a lifetime
      Active --> [*] : remove, or its script's remove
      Expired --> [*] : remove, or its script's remove

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

  alias YmerNode.Repo
  alias YmerNode.Schedules.{Cron, InFlight, LastRun, Lifetime, Schedule}
  alias YmerNode.Script.Context
  alias YmerNode.Scripts
  alias YmerNode.Scripts.Runner
  alias YmerNode.Scripts.Script

  # ─── Reading ────────────────────────────────────────────────────────

  @doc """
  Every schedule, ordered by name: what runs, when next, until when, and how the
  last run went — the shape `add/1` and `update/2` answer too.

  Each entry carries `name`, `script`, `action`, `args`, `cron_expression`,
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
  loaded: a firing reads its script afresh (`fire/2`).
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
         {:ok, attrs} <- changed(schedule, changes) do
      schedule
      |> Schedule.changeset(attrs)
      |> Repo.update()
      |> answered(name)
    end
  end

  @doc "Removes a schedule, answering the row that went."
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
  firing runs whatever is accepted under that name at this moment.
  """
  def fire(%Schedule{} = schedule, %DateTime{} = fired_at) do
    started = System.monotonic_time(:millisecond)

    case prepare(schedule) do
      {:ok, script, schema} -> run_once(schedule, script, schema, {fired_at, started})
      {:error, _reason} = refusal -> record(schedule, refusal, {fired_at, started})
    end
  end

  defp prepare(%Schedule{script_id: id, action: action, args: args}) do
    case Repo.get(Script, id) do
      nil ->
        {:error, {:not_found, "the script this schedule runs is gone"}}

      %Script{} = script ->
        with {:ok, schema} <- Runner.check(script, action, args), do: {:ok, script, schema}
    end
  end

  # The entry is taken before the run and dropped after it, whatever happens;
  # the process registry drops it anyway if this process dies, so a killed
  # firing never leaves its schedule skipping for ever.
  defp run_once(schedule, script, schema, timing) do
    until = latest_end(Runner.longest(schema))

    case InFlight.register(schedule.id, schedule.name, script.name, until) do
      :ok -> run_registered(schedule, script, timing)
      :in_flight -> :skipped
    end
  end

  # The entry goes as the run ends, before the record is written: a refusal
  # read while the record waits on the database names no finished run.
  defp run_registered(schedule, script, timing) do
    result =
      try do
        Scripts.run(script.name, schedule.action, schedule.args)
      after
        InFlight.unregister(schedule.id)
      end

    record(schedule, result, timing)
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

      Repo.exists?(from schedule in Schedule, where: schedule.name == ^name) ->
        {:error, taken(name)}

      true ->
        :ok
    end
  end

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

  defp taken(name) do
    {:name_taken,
     "a schedule named #{name} already exists — update it, or remove it and add it again"}
  end

  defp not_found(name), do: {:not_found, "no schedule named #{name}"}

  # ─── Shaping a read ─────────────────────────────────────────────────

  defp entry(%Schedule{} = schedule, now) do
    zone = Context.time_zone()
    expired? = DateTime.compare(schedule.ends_at, now) != :gt

    %{
      name: schedule.name,
      script: schedule.script.name,
      action: schedule.action,
      args: schedule.args,
      cron_expression: schedule.cron_expression,
      state: if(expired?, do: "expired", else: "active"),
      ends_at: render(schedule.ends_at, zone),
      next_firing: if(expired?, do: nil, else: next_firing(schedule, now, zone)),
      last_run: last_run(schedule, zone)
    }
  end

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
