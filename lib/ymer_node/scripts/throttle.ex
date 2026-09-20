defmodule YmerNode.Scripts.Throttle do
  @moduledoc """
  One throttle on this node: the process that holds its bucket, its breaker and
  the requests waiting on it — and the two request steps that put a request
  naming it through that process.

  What a throttle is, and how a script declares and names one, is written at
  `t:YmerNode.Script.throttle/0` and in `YmerNode.Script.Context`'s Throttles
  section; this module is how the node keeps that promise.

  ## One process per name, started by the first request

  A throttle is a process registered under its name in
  `YmerNode.Scripts.Throttles` and started under
  `YmerNode.Scripts.ThrottleSupervisor` by the first request that names it —
  never at boot, because nothing needs a throttle before a script asks for one.
  It starts holding that request's parameters, so a throttle the registry names
  always has a bucket to report, even to a listing that reaches it before that
  request is served. It lives across runs and across the scripts that name it,
  and a node that restarts forgets it: tokens and a breaker's count are nothing
  a restart owes anyone, which is the durability rule applied (`YmerNode`). It
  is started `:temporary`, so a throttle that crashed is started fresh by the
  next request rather than counting against its supervisor's restarts.

  Its parameters arrive with every request, from the declaration of the script
  making it. A script updated to other parameters is therefore obeyed at its
  next request: the bucket is refilled at the old rate up to that moment and
  held to the new burst (`YmerNode.Scripts.Throttle.Bucket.configure/4`), while
  the breaker keeps its state and its count — an open one stays open, and is
  listed open, even when the new declaration drops the breaker — because a
  locked account stays locked whatever numbers a script now declares. Two
  accepted scripts only ever hand one name the same parameters —
  `YmerNode.Scripts` refuses the write that would disagree.

  ## Waiting

  A request takes a token when the bucket holds one and nobody is waiting;
  otherwise it waits its turn, first come first served. It waits at most until
  its run's deadline: a request the tokens and the waiters ahead say cannot be
  served before then is refused at once, naming the wait it would need
  (`YmerNode.Scripts.Throttle.Bucket.wait/2`), so a run never sits in a queue
  until the runner kills it with an answer that names the run and not the
  throttle. The estimate counts every waiter ahead as taking its token, so a
  request it lets wait is served in time unless a lower rate arrives meanwhile,
  and then the runner's kill at the deadline ends the wait.

  Every waiter is monitored. The runner kills a run at its deadline as a matter
  of course, so a waiter dying in the queue is the ordinary case, and a dead
  waiter is dropped when its monitor fires and never handed a token.

  ## The breaker

  A throttle declared with a breaker counts consecutive 401 responses. At the
  threshold it opens: every waiter is answered at once, and every request is
  refused until the cooldown passes or an operator resets it with the CLI
  (`YmerNode.Scripts.CLI`) — the operator's door and not a session's, because a
  session able to reset it would reset it against the very failure it guards.
  There is no half-open trial: the bucket already bounds how many requests
  start at once, so a wrong secret costs at most the threshold's worth of failed
  logins per cooldown.

  ```mermaid
  stateDiagram-v2
      [*] --> Closed : the first request naming it
      Closed --> Closed : a 401 below the threshold, or any other status
      Closed --> Open : the threshold's consecutive 401
      Open --> Closed : the cooldown passes
      Open --> Closed : an operator resets it
      note right of Open
          every waiter and every new request
          is refused at once; a response
          arriving now is ignored
      end note
  ```

  Any status but 401 zeroes the count, which is what tells a changed password
  from a busy hour; a request that got no response — a transport error — leaves
  the count as it was. The opening is logged as a warning naming the count and
  the cooldown, the closing as info naming how it closed.

  ## The steps

  `attach/3` adds two steps to a Req request, and they sit on opposite sides of
  Req's own. The request step is **appended**: Req re-runs every request step
  for a retried attempt, so each attempt pays a token. The response step is
  **prepended**: Req's retry is itself a response step, and a step behind it
  sees only the last attempt's status, so a breaker fed there would miss the
  401s of every attempt but the last. A refusal halts the request with a
  `YmerNode.Scripts.Throttle.Error` before anything is sent, and a halted request
  runs no error step, so no retry policy a script passes can retry a refusal.
  """
  use GenServer, restart: :temporary

  require Logger

  alias YmerNode.Scripts.Throttle.Bucket
  alias YmerNode.Scripts.Throttle.Error

  @registry YmerNode.Scripts.Throttles
  @supervisor YmerNode.Scripts.ThrottleSupervisor

  # ─── Public API ─────────────────────────────────────────────────────

  @doc false
  def start_link({name, parameters}) when is_binary(name) and is_map(parameters) do
    GenServer.start_link(__MODULE__, {name, parameters},
      name: {:via, Registry, {@registry, name}}
    )
  end

  @doc """
  Takes one of the named throttle's tokens for a request, starting the throttle
  if nothing has named it since the node started.

  `parameters` are the declaring script's, and the throttle adopts them before
  it answers; `deadline` is the run's, as a `System.monotonic_time(:millisecond)`
  instant. Answers `:ok` once a token is the caller's, or
  `{:error, %YmerNode.Scripts.Throttle.Error{}}` — at once — when the breaker is
  open or the wait would outlast the deadline.
  """
  def take(name, parameters, deadline)
      when is_binary(name) and is_map(parameters) and is_integer(deadline) do
    GenServer.call(started(name, parameters), {:take, parameters, deadline}, :infinity)
  end

  @doc """
  Hands the named throttle the status of a response to a request it gave a token
  to. Asynchronous, and nothing at all when no throttle of that name has
  started.
  """
  def record(name, status) when is_binary(name) and is_integer(status) do
    case Registry.lookup(@registry, name) do
      [{pid, _value}] -> GenServer.cast(pid, {:record, status})
      [] -> :ok
    end
  end

  @doc """
  Every throttle this node has started, in name order: its tokens, burst and
  rate, how many requests wait on it, and its breaker — `nil` for a bucket
  alone, otherwise the threshold, the count, and `resumes_in`, the milliseconds
  until an open breaker closes by itself (`nil` while it is closed). A breaker
  a new declaration dropped while it was open stays listed until it closes,
  with a `nil` threshold.
  """
  def list do
    @registry
    |> Registry.select([{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.sort()
    |> Enum.flat_map(fn {_name, pid} -> state_of(pid) end)
  end

  @doc """
  Closes the named throttle's breaker and clears its count — the operator's
  verb. Answers `:ok`, or `{:error, {:throttle_not_started, detail}}` when no
  throttle of that name has started on this node.
  """
  def reset(name) when is_binary(name) do
    case Registry.lookup(@registry, name) do
      [{pid, _value}] -> GenServer.call(pid, :reset)
      [] -> {:error, {:throttle_not_started, "no throttle #{name} has started on this node"}}
    end
  end

  @doc """
  Puts a Req request through the throttle its `throttle:` option names, among
  the ones `declared` — name to parameters — and within `deadline`. A request
  naming none passes both steps untouched, and one naming a throttle `declared`
  does not hold is refused before it is sent. Why the two steps sit where they
  do is § The steps above.
  """
  def attach(%Req.Request{} = request, declared, deadline)
      when is_map(declared) and is_integer(deadline) do
    request
    |> Req.Request.register_options([:throttle])
    |> Req.Request.put_private(:throttle, %{declared: declared, deadline: deadline})
    |> Req.Request.append_request_steps(throttle: &take_step/1)
    |> Req.Request.prepend_response_steps(throttle: &record_step/1)
  end

  # A throttle that exited between the registry's answer and the call is simply
  # not listed: the next request naming it starts it again.
  defp state_of(pid) do
    [GenServer.call(pid, :state)]
  catch
    :exit, _reason -> []
  end

  defp started(name, parameters) do
    case Registry.lookup(@registry, name) do
      [{pid, _value}] -> pid
      [] -> start(name, parameters)
    end
  end

  # Two first requests racing for one name both reach the supervisor; the
  # registry lets one start and hands the other the winner, whose take then
  # adopts that request's parameters as it adopts any request's.
  defp start(name, parameters) do
    case DynamicSupervisor.start_child(@supervisor, {__MODULE__, {name, parameters}}) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  # ─── The steps ──────────────────────────────────────────────────────

  defp take_step(request) do
    case Req.Request.get_option(request, :throttle) do
      nil -> request
      name -> take_for(request, name)
    end
  end

  defp take_for(request, name) do
    %{declared: declared, deadline: deadline} = Req.Request.get_private(request, :throttle)

    with {:ok, parameters} <- declared_parameters(declared, name),
         :ok <- take(name, parameters, deadline) do
      request
    else
      {:error, %Error{} = refusal} -> Req.Request.halt(request, refusal)
    end
  end

  defp declared_parameters(declared, name) do
    with :error <- Map.fetch(declared, name), do: {:error, Error.undeclared(name)}
  end

  defp record_step({request, response}) do
    case Req.Request.get_option(request, :throttle) do
      nil -> :ok
      name -> record(name, response.status)
    end

    {request, response}
  end

  # ─── The process ────────────────────────────────────────────────────

  # The registry names the process before this runs, but a call waits for it to
  # return, so adopting the first request's parameters here means no listing
  # ever reaches a throttle without a bucket.
  @impl true
  def init({name, parameters}) do
    state = %{
      name: name,
      bucket: nil,
      breaker: nil,
      failures: 0,
      open: nil,
      waiters: :queue.new(),
      drain: nil
    }

    {:ok, adopt(state, parameters, now())}
  end

  @impl true
  def handle_call({:take, parameters, deadline}, from, state) do
    now = now()
    state = state |> adopt(parameters, now) |> serve(now)

    case admit(state, deadline, now) do
      :token -> {:reply, :ok, %{state | bucket: Bucket.take(state.bucket)}}
      :wait -> {:noreply, enqueue(state, from, now)}
      {:refuse, refusal} -> {:reply, {:error, refusal}, state}
    end
  end

  def handle_call(:state, _from, state) do
    now = now()
    state = serve(state, now)

    {:reply, describe(state, now), state}
  end

  def handle_call(:reset, _from, %{open: nil} = state), do: {:reply, :ok, %{state | failures: 0}}

  def handle_call(:reset, _from, state) do
    Process.cancel_timer(state.open.timer)

    {:reply, :ok, close(state, "an operator reset it")}
  end

  @impl true
  def handle_cast({:record, _status}, %{breaker: nil} = state), do: {:noreply, state}
  def handle_cast({:record, _status}, %{open: %{}} = state), do: {:noreply, state}
  def handle_cast({:record, 401}, state), do: {:noreply, count_401(state)}
  def handle_cast({:record, _status}, state), do: {:noreply, %{state | failures: 0}}

  @impl true
  def handle_info(:drain, state) do
    now = now()

    {:noreply, %{state | drain: nil} |> serve(now) |> schedule_drain(now)}
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    waiters = :queue.filter(fn {_from, waiter} -> waiter != monitor end, state.waiters)

    {:noreply, schedule_drain(%{state | waiters: waiters}, now())}
  end

  def handle_info({:close, id}, %{open: %{id: id}} = state),
    do: {:noreply, close(state, "the cooldown passed")}

  # A cooldown's message that a reset already overtook.
  def handle_info({:close, _stale}, state), do: {:noreply, state}

  # ─── The bucket and the queue ───────────────────────────────────────

  defp adopt(state, %{rate: rate, burst: burst} = parameters, now) do
    bucket =
      case state.bucket do
        nil -> Bucket.new(rate, burst, now)
        bucket -> Bucket.configure(bucket, rate, burst, now)
      end

    %{state | bucket: bucket, breaker: Map.get(parameters, :breaker)}
  end

  # Called after `serve/2`, so a bucket holding a token has nobody waiting ahead
  # of this request, and a request with waiters ahead is told how long they take.
  defp admit(state, deadline, now) do
    needed = Bucket.wait(state.bucket, :queue.len(state.waiters))

    cond do
      state.open != nil ->
        {:refuse, open_refusal(state, now)}

      needed == 0 ->
        :token

      now + needed > deadline ->
        {:refuse, Error.deadline(state.name, needed, max(deadline - now, 0))}

      true ->
        :wait
    end
  end

  defp enqueue(state, {pid, _tag} = from, now) do
    waiter = Process.monitor(pid)

    schedule_drain(%{state | waiters: :queue.in({from, waiter}, state.waiters)}, now)
  end

  defp serve(state, now), do: serve_waiters(%{state | bucket: Bucket.refill(state.bucket, now)})

  # A waiter whose :DOWN is already in the mailbox died before its turn came:
  # demonitor answers false for it, and it is dropped without a token.
  defp serve_waiters(state) do
    with true <- Bucket.available?(state.bucket),
         {{:value, {from, waiter}}, rest} <- :queue.out(state.waiters) do
      if Process.demonitor(waiter, [:flush, :info]) do
        GenServer.reply(from, :ok)
        serve_waiters(%{state | waiters: rest, bucket: Bucket.take(state.bucket)})
      else
        serve_waiters(%{state | waiters: rest})
      end
    else
      _nothing_to_serve -> state
    end
  end

  # One timer at a time, set for the moment the first waiter's token is there. A
  # drain that arrives early or twice serves nobody out of turn.
  defp schedule_drain(state, now) do
    if state.drain, do: Process.cancel_timer(state.drain)

    if :queue.is_empty(state.waiters) do
      %{state | drain: nil}
    else
      wait = state.bucket |> Bucket.refill(now) |> Bucket.wait(0)
      %{state | drain: Process.send_after(self(), :drain, wait)}
    end
  end

  # ─── The breaker ────────────────────────────────────────────────────

  defp count_401(%{failures: failures, breaker: %{threshold: threshold}} = state)
       when failures + 1 >= threshold,
       do: open(%{state | failures: failures + 1})

  defp count_401(state), do: %{state | failures: state.failures + 1}

  defp open(%{name: name, failures: failures, breaker: %{cooldown: cooldown}} = state) do
    Logger.warning(
      "throttle #{name} opened after #{failures} consecutive 401s; it closes in " <>
        "#{cooldown} ms unless an operator resets it"
    )

    refusal = Error.open(name, failures, cooldown)

    state.waiters
    |> :queue.to_list()
    |> Enum.each(fn {from, waiter} ->
      Process.demonitor(waiter, [:flush])
      GenServer.reply(from, {:error, refusal})
    end)

    if state.drain, do: Process.cancel_timer(state.drain)
    id = make_ref()
    timer = Process.send_after(self(), {:close, id}, cooldown)

    %{
      state
      | open: %{id: id, timer: timer, until: now() + cooldown},
        waiters: :queue.new(),
        drain: nil
    }
  end

  defp open_refusal(state, now) do
    Error.open(state.name, state.failures, max(state.open.until - now, 0))
  end

  defp close(state, how) do
    Logger.info("throttle #{state.name} closed — #{how}")

    %{state | open: nil, failures: 0}
  end

  defp describe(state, now) do
    %{
      name: state.name,
      tokens: state.bucket.tokens,
      burst: state.bucket.burst,
      rate: state.bucket.rate,
      waiters: :queue.len(state.waiters),
      breaker: breaker_state(state, now)
    }
  end

  # A declaration that dropped the breaker while it was open leaves it open —
  # the lockout is the account's — so it is listed until it closes.
  defp breaker_state(%{breaker: nil, open: nil}, _now), do: nil

  defp breaker_state(state, now) do
    %{
      threshold: state.breaker && state.breaker.threshold,
      failures: state.failures,
      resumes_in: state.open && max(state.open.until - now, 0)
    }
  end

  defp now, do: System.monotonic_time(:millisecond)
end
