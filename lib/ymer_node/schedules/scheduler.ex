defmodule YmerNode.Schedules.Scheduler do
  @moduledoc """
  The process that fires schedules: once a minute, on the minute, it reads the
  active schedules and starts a firing for each one due in that minute — each in
  a task of its own under `YmerNode.Schedules.FiringSupervisor`, so a long run
  never holds the next minute back.

  ## The next firing is carried, not recomputed

  For each schedule the process keeps the next firing it expects, and walks the
  cron expression again only when that firing comes due or has gone by: one
  walk a firing, rather than one a minute for every schedule. What is carried is
  not what keeps a time from firing twice when the clock falls back —
  `YmerNode.Schedules.Cron.next_firing/2` never answers the second pass of a
  repeated hour, from whichever minute it is asked — so a restart, or a changed
  expression found afresh, fires nothing a carried walk would not have.

  A next firing already gone by when its minute is read — the node was asleep, or
  not yet up — is dropped, and the next one is found from the minute at hand: a
  missed firing is skipped, never caught up. The carried firings live in this
  process and nowhere else, so a restart starts again from the minute it comes up.
  They are keyed by schedule and cron expression, so an `update` that changes the
  expression is found afresh.

  `plan/4` is that decision — a deterministic function of the carried firings,
  the schedules and the minute — and the process is the clock around it.

  `config/test.exs` turns the process off (`enabled?/0`): it would read the node
  database every minute with no sandbox owner. The suite drives `plan/4` and
  `YmerNode.Schedules.fire/2` itself, and hands `handle_info/2` one minute by
  hand, inside a case's own sandbox, for the wiring between them.
  """
  use GenServer

  alias YmerNode.Schedules
  alias YmerNode.Schedules.Cron
  alias YmerNode.Script.Context

  @firings YmerNode.Schedules.FiringSupervisor

  # ─── Runtime configuration ──────────────────────────────────────────

  @doc """
  Whether the scheduler runs (`config :ymer_node, YmerNode.Schedules.Scheduler,
  :enabled`). Defaults to enabled; `config/test.exs` turns it off.
  """
  def enabled? do
    :ymer_node
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:enabled, true)
  end

  # ─── Public API ─────────────────────────────────────────────────────

  def start_link(_options), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Decides one minute: the schedules that fire at `minute`, and the next firing
  each schedule carries into the minutes after it.

  `carried` is the previous call's second element, `%{}` at the start. `minute`
  is a UTC `DateTime` on the minute, read in `zone`, and `schedules` are the
  active ones; a schedule no longer among them drops out of what is carried.
  """
  def plan(carried, schedules, %DateTime{} = minute, zone)
      when is_map(carried) and is_list(schedules) and is_binary(zone) do
    local = DateTime.shift_zone!(minute, zone)
    {due, next} = Enum.reduce(schedules, {[], %{}}, &step(&1, &2, carried, local))

    {Enum.reverse(due), next}
  end

  @impl true
  def init(:ok) do
    if enabled?() do
      arm()
      {:ok, %{carried: %{}}}
    else
      :ignore
    end
  end

  @impl true
  def handle_info(:minute, state) do
    minute = %{DateTime.truncate(DateTime.utc_now(), :second) | second: 0}
    schedules = Schedules.active(minute)
    {due, carried} = plan(state.carried, schedules, minute, Context.time_zone())

    Enum.each(due, &start_firing(&1, minute))
    arm()

    {:noreply, %{state | carried: carried}}
  end

  # ─── The minute ─────────────────────────────────────────────────────

  defp step(schedule, {due, next}, carried, local) do
    key = {schedule.id, schedule.cron_expression}
    expected = expected(Map.fetch(carried, key), schedule.cron_expression, local)

    if due_now?(expected, local) do
      {[schedule | due], Map.put(next, key, after_firing(schedule.cron_expression, local))}
    else
      {due, Map.put(next, key, expected)}
    end
  end

  # A carried firing still ahead stands; one gone by, or none carried yet, is
  # found from the minute at hand.
  defp expected({:ok, :none}, _expression, _local), do: :none

  defp expected({:ok, %DateTime{} = firing}, expression, local) do
    if DateTime.compare(firing, local) == :lt, do: first_from(expression, local), else: firing
  end

  defp expected(:error, expression, local), do: first_from(expression, local)

  defp due_now?(:none, _local), do: false
  defp due_now?(firing, local), do: DateTime.compare(firing, local) == :eq

  defp after_firing(expression, local),
    do: first_from(expression, DateTime.add(local, 60, :second))

  defp first_from(expression, from) do
    case Cron.parse(expression) do
      {:ok, cron} -> Cron.next_firing(cron, from)
      {:error, _refused} -> :none
    end
  end

  # ─── The clock ──────────────────────────────────────────────────────

  # The next minute's boundary, read off the system clock each time rather than
  # counted from the last one, so a slow minute never drifts the next.
  defp arm do
    now = System.os_time(:millisecond)
    Process.send_after(self(), :minute, 60_000 - rem(now, 60_000))
  end

  defp start_firing(schedule, minute) do
    Task.Supervisor.start_child(@firings, fn -> Schedules.fire(schedule, minute) end)
  end
end
