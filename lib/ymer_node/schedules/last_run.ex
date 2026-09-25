defmodule YmerNode.Schedules.LastRun do
  @moduledoc """
  What a schedule's row keeps of its last run: the moment the firing that started
  it came due, one of four outcomes, the runner's own message, and how long the
  run took. Nothing before it — there is no run history, and a skipped firing
  leaves no trace — because the node is a script runner, not a reliable
  scheduler. What a script produces goes where the script puts it; anything it
  wants kept beyond one line, it writes to the notebook.

  The outcome answers "did it work, and whose move is it" in one word, grouping
  the reasons `YmerNode.Scripts.Runner` tabulates:

  | outcome | reasons | whose move |
  | --- | --- | --- |
  | `ok` | — | nobody's |
  | `refused` | `:not_found`, `:not_accepted`, `:not_loaded`, `:unknown_action`, `:invalid_schema`, `:invalid_args` | the run never started: fix the schedule, or accept the script |
  | `error` | `:script_error`, `:script_raised`, `:script_exited`, `:bad_return`, `:result_not_encodable` | the script ran and failed: fix the script |
  | `timeout` | `:timeout` | the run passed its deadline and was killed |

  `:not_found` is the one reason that is not the runner's: the script's row gone
  between a firing and its run. A script's schedules are deleted with it, so only
  that window can see it.

  The message is the runner's rendered text, cut short at a fixed length: it is
  a line to read in a listing, not a log.
  """

  @refused [
    :not_found,
    :not_accepted,
    :not_loaded,
    :unknown_action,
    :invalid_schema,
    :invalid_args
  ]
  @message_limit 500

  @doc """
  The row's last-run fields for one run's answer.

  ## Examples

      iex> YmerNode.Schedules.LastRun.attrs({:ok, %{"pong" => true}}, ~U[2026-09-26 07:00:00Z], 12)
      %{last_fired_at: ~U[2026-09-26 07:00:00Z], last_outcome: "ok", last_message: nil, last_run_ms: 12}

      iex> YmerNode.Schedules.LastRun.attrs({:error, {:timeout, "hex fetch: no answer in 30000 ms, run killed"}}, ~U[2026-09-26 07:00:00Z], 30_001)
      %{last_fired_at: ~U[2026-09-26 07:00:00Z], last_outcome: "timeout", last_message: "hex fetch: no answer in 30000 ms, run killed", last_run_ms: 30_001}

  """
  def attrs(result, %DateTime{} = fired_at, took_ms) when is_integer(took_ms) do
    %{
      last_fired_at: DateTime.truncate(fired_at, :second),
      last_outcome: outcome(result),
      last_message: message(result),
      last_run_ms: took_ms
    }
  end

  @doc """
  The outcome one run's answer is recorded as.

  ## Examples

      iex> YmerNode.Schedules.LastRun.outcome({:error, {:not_accepted, "hex is not accepted"}})
      "refused"

      iex> YmerNode.Schedules.LastRun.outcome({:error, {:script_raised, "hex fetch: boom"}})
      "error"

  """
  def outcome({:ok, _value}), do: "ok"
  def outcome({:error, {:timeout, _detail}}), do: "timeout"
  def outcome({:error, {reason, _detail}}) when reason in @refused, do: "refused"
  def outcome({:error, _reason}), do: "error"

  defp message({:ok, _value}), do: nil
  defp message({:error, {_reason, detail}}) when is_binary(detail), do: cut(detail)
  defp message({:error, reason}), do: reason |> inspect() |> cut()

  defp cut(text) do
    if String.length(text) > @message_limit do
      String.slice(text, 0, @message_limit - 1) <> "…"
    else
      text
    end
  end
end
