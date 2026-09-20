defmodule YmerNode.Scripts.Throttle.Error do
  @moduledoc """
  A throttle's refusal of a request — the exception `YmerNode.Script.Context.request/2`
  answers as `{:error, exception}` when a request never left the node.

  An exception rather than a term, because Req's pipeline carries one: a request
  step refuses by halting with an exception, and `Req.request/2` hands it back
  as it came. Its message is what a run's answer shows whichever way a script
  meets it. Handed back from `run/3`, `YmerNode.Scripts.Runner` renders it by its
  message after the script and the action; left in a failed `{:ok, _} =` match,
  its fields — the message among them — are printed inside the match error. So
  the reader learns what only the node knows either way: which throttle, what
  stopped the request, and the verb or the wait that answers it.

  `reason` is `:undeclared`, `:open` or `:deadline`, and `throttle` is the name
  the request gave.
  """
  defexception [:reason, :throttle, :message]

  @doc "A request named a throttle its script's declarations do not name."
  def undeclared(name) do
    %__MODULE__{
      reason: :undeclared,
      throttle: name,
      message:
        "the script asked for the throttle #{name}, which its declarations/0 does not " <>
          "name — declare it and accept the code again"
    }
  end

  @doc """
  The throttle's breaker is open after `failures` consecutive 401s, and closes by
  itself in `resumes_in` milliseconds.
  """
  def open(name, failures, resumes_in) when is_integer(failures) and is_integer(resumes_in) do
    %__MODULE__{
      reason: :open,
      throttle: name,
      message:
        "the throttle #{name} stopped sending after #{failures} consecutive 401s; it " <>
          "resumes in #{seconds_up(resumes_in)}s, or an operator resets it with " <>
          "`ymer-node throttles reset #{name}`"
    }
  end

  @doc """
  The throttle cannot give a token before the run's deadline: the wait would be
  `needed` milliseconds, and the run has `left`.
  """
  def deadline(name, needed, left) when is_integer(needed) and is_integer(left) do
    %__MODULE__{
      reason: :deadline,
      throttle: name,
      message:
        "the throttle #{name} cannot give a token before the run's deadline — about " <>
          "#{seconds_up(needed)}s needed, #{div(left, 1_000)}s left"
    }
  end

  # Up, so a wait the sentence names is never shorter than the real one.
  defp seconds_up(milliseconds), do: div(milliseconds + 999, 1_000)
end
