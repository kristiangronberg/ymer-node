defmodule YmerNode.Messages do
  @moduledoc """
  How sessions talk with each other through the node: a session sends a
  message to a [*thread*](docs/glossary.md#thread), and whoever reads that
  thread sees it. No message is addressed to a recipient. The process keys
  every message and every read mark by the thread and by the session's
  [*handle*](docs/glossary.md#handle), passed as `as`, and only ever compares
  the two: it validates neither and reads no meaning into either.

  This process holds every message and every read mark, in memory and nowhere
  else — `YmerNode.Messages.Threads` is the value it holds and the rules for
  what each call does to it. Nothing persists: a restart, an upgrade included,
  loses every message and every read mark. That is the design, not a gap. It is
  also why every answer that finds nothing says when messages started — the
  process's own start — so a session waiting on a reply after a restart reads a
  lost conversation rather than a silent one. A thread only a check has joined,
  and a named thread a read's filter leaves empty, say so the same way.

  ## Bounds

  A body over 8 KB is refused with where to put the content instead, and a
  handle or thread name over 512 bytes is refused too: together they bound what
  one kept message holds, and each message keeps its own copy of those strings
  rather than the request it arrived in. Past 10 000 messages the oldest is
  dropped, and a check or a read that reaches back past it says so. A thread's
  entry is never dropped — a check by any name makes one — which the node's
  load, a few sessions on one machine, keeps small.

  A page holds at most 20 messages and at most 32 KB of them, measured as each
  message will be sent: a client parks a tool result much past that size
  instead of reading it, and an unread page is the token waste this tool is
  there to avoid.

  ## Time

  Every time an answer carries is in the
  [*node time zone*](docs/glossary.md#node-time-zone) with its offset, and a
  read's `since` is a span back from now or a date-time; how each is read and
  written is `YmerNode.Messages.Clock`.

  Nothing here is part of a script's run, so this process is not in
  `YmerNode.Script.Harness.run_tree/0`, and `YmerNode.Script.Context` offers a
  script no way to send a message.
  """
  use GenServer

  alias YmerNode.Messages.{Clock, Message, Threads}
  alias YmerNode.Script.Context

  @body_limit 8_192
  @name_limit 512
  @count_cap 10_000
  @page_count 20
  @page_bytes 32_768
  @last_default 10

  @doc """
  Starts the process. Besides `:name` it takes `:zone`, the zone every time is
  read and rendered in; left out, that is the node time zone, read on each
  call. A test passes one to run the time rules in a zone with summer time.
  """
  def start_link(options) when is_list(options) do
    {name, options} = Keyword.pop(options, :name, __MODULE__)
    GenServer.start_link(__MODULE__, options, name: name)
  end

  @doc """
  Sends `body` to `thread` as `handle`. A body over 8 KB, or a handle or thread
  over 512 bytes, is refused before it reaches the process.
  """
  def send(handle, thread, body, server \\ __MODULE__)
      when is_binary(handle) and is_binary(thread) and is_binary(body) do
    with :ok <- body_fits(body), :ok <- names_fit([handle, thread]) do
      GenServer.call(server, {:send, handle, thread, body})
    end
  end

  @doc """
  What is new for `handle` on `thread`, oldest first, moving its read mark past
  what it returns. With `thread` `nil` it is the threads `handle` has taken part
  in that hold unread messages, with counts, and no mark moves.
  """
  def check(handle, thread, server \\ __MODULE__)
      when is_binary(handle) and (is_binary(thread) or is_nil(thread)) do
    with :ok <- names_fit(Enum.reject([handle, thread], &is_nil/1)) do
      GenServer.call(server, {:check, handle, thread})
    end
  end

  @doc """
  Looks without moving any mark. `filters` may hold `thread` — a name or a list
  of names — `last`, `before` and `since`. With none of them it answers the
  thread index. `last` or `before` with neither `thread` nor `since` is refused:
  they page through messages, and nothing names the messages to page through.
  """
  def read(filters, server \\ __MODULE__) when is_map(filters) do
    filters = Map.merge(%{thread: nil, last: nil, before: nil, since: nil}, filters)

    with :ok <- reads_something(filters), :ok <- names_fit(List.wrap(filters.thread)) do
      GenServer.call(server, {:read, filters})
    end
  end

  @impl true
  def init(options),
    do: {:ok, %{threads: Threads.new(@count_cap), started_at: now(), zone: options[:zone]}}

  @impl true
  def handle_call({:send, handle, thread, body}, _from, state) do
    {message, threads} = Threads.post(state.threads, handle, thread, body, now())
    answer = %{id: message.id, thread: thread, at: Clock.format(message.at, zone(state))}

    {:reply, {:ok, answer}, %{state | threads: threads}}
  end

  def handle_call({:check, handle, nil}, _from, state),
    do: {:reply, {:ok, pending(state, handle, zone(state))}, state}

  def handle_call({:check, handle, thread}, _from, state) do
    zone = zone(state)
    {answer, threads} = Threads.check(state.threads, handle, thread, now(), page(zone))
    state = %{state | threads: threads}

    {:reply, {:ok, checked(answer, handle, thread, state, zone)}, state}
  end

  def handle_call({:read, filters}, _from, state) do
    zone = zone(state)

    case Clock.since(filters.since, now(), zone) do
      {:ok, since} -> {:reply, {:ok, looked(%{filters | since: since}, state, zone)}, state}
      {:error, _reason} = refused -> {:reply, refused, state}
    end
  end

  # ─── Refusals ───────────────────────────────────────────────────────

  defp body_fits(body) when byte_size(body) <= @body_limit, do: :ok

  defp body_fits(body),
    do:
      {:error,
       {:body_too_large,
        "the body is #{byte_size(body)} bytes, over the #{@body_limit} a message holds"}}

  defp names_fit(names) do
    case Enum.find(names, &(byte_size(&1) > @name_limit)) do
      nil ->
        :ok

      name ->
        {:error,
         {:name_too_long,
          "a handle or thread name of #{byte_size(name)} bytes is over the #{@name_limit} " <>
            "one holds"}}
    end
  end

  defp reads_something(%{thread: nil, since: nil, last: last, before: before})
       when not is_nil(last) or not is_nil(before) do
    given =
      [last: last, before: before]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Enum.map_join(" and ", fn {key, value} -> "#{key} #{value}" end)

    {:error, {:read_needs_thread, "read was given #{given} but neither thread nor since"}}
  end

  defp reads_something(_filters), do: :ok

  # ─── Checks ─────────────────────────────────────────────────────────

  defp checked(%{messages: []} = answer, handle, thread, state, zone) do
    elsewhere = state.threads |> Threads.unread(handle) |> Enum.reject(&(&1.thread == thread))

    present(%{
      thread: thread,
      notice: nothing_new(answer, handle, thread, started(state, zone), zone),
      dropped: dropped(thread, answer.dropped_at, zone),
      elsewhere: elsewhere
    })
  end

  defp checked(answer, _handle, thread, _state, zone) do
    present(%{
      thread: thread,
      messages: Enum.map(answer.messages, &render(&1, zone)),
      more_unread: if(answer.more > 0, do: answer.more),
      dropped: dropped(thread, answer.dropped_at, zone)
    })
  end

  defp nothing_new(%{posted?: false}, _handle, thread, started, _zone),
    do: never_posted(thread, started)

  defp nothing_new(%{last_check: nil}, handle, thread, started, _zone),
    do: "nothing new on #{thread} for #{handle} — messages started at #{started}"

  defp nothing_new(%{last_check: last_check}, handle, thread, started, zone),
    do:
      "nothing new on #{thread} since #{handle}'s last check at " <>
        "#{Clock.format(last_check, zone)} — messages started at #{started}"

  defp pending(state, handle, zone) do
    started = started(state, zone)

    case {Threads.unread(state.threads, handle), Threads.joined?(state.threads, handle)} do
      {[], true} ->
        %{notice: "nothing new for #{handle} on any thread — messages started at #{started}"}

      {[], false} ->
        %{
          notice:
            "#{handle} has taken part in no thread since messages started at #{started}; " <>
              "read {} lists every thread, and a check by name joins one"
        }

      {threads, _joined?} ->
        %{threads: threads}
    end
  end

  # ─── Reads ──────────────────────────────────────────────────────────

  defp looked(%{thread: nil, since: nil}, state, zone) do
    case Threads.index(state.threads) do
      [] ->
        %{notice: "no thread since messages started at #{started(state, zone)}"}

      rows ->
        %{
          started_at: started(state, zone),
          threads:
            Enum.map(rows, fn row ->
              present(%{
                thread: row.thread,
                count: row.count,
                last_activity: Clock.format(row.last_at, zone),
                handles: row.handles
              })
            end)
        }
    end
  end

  defp looked(filters, state, zone) do
    last = (filters.last || @last_default) |> max(1) |> min(@page_count)
    reading = %{last: last, before: filters.before, since: filters.since}
    answer = Threads.read(state.threads, names(filters.thread), reading, page(zone))

    case answer.threads do
      [] ->
        %{
          notice:
            "nothing #{below(filters.before)}since #{Clock.format(filters.since, zone)} — " <>
              "messages started at #{started(state, zone)}"
        }

      threads ->
        present(%{
          threads: Enum.map(threads, &thread_read(&1, state, zone)),
          next_cursor: answer.cursor
        })
    end
  end

  defp below(nil), do: ""
  defp below(before), do: "before id #{before} "

  defp names(nil), do: :all
  defp names(thread) when is_binary(thread), do: [thread]
  defp names(threads) when is_list(threads), do: threads

  defp thread_read(%{header: nil, thread: thread}, state, zone),
    do: %{thread: thread, notice: never_posted(thread, started(state, zone))}

  defp thread_read(read, state, zone) do
    present(%{
      thread: read.thread,
      notice: empty(read, started(state, zone)),
      count: read.header.count,
      last_activity: Clock.format(read.header.last_at, zone),
      handles: Enum.map(read.header.handles, &handle_line(&1, zone)),
      messages: Enum.map(read.messages, &render(&1, zone)),
      dropped: dropped(read.thread, read.dropped_at, zone)
    })
  end

  # Why a named thread answers no message: the page went to newer messages of
  # the other threads read, the thread never held one, the count cap took all
  # it held, or the filter matched none.
  defp empty(%{messages: [_ | _]}, _started), do: nil

  defp empty(%{matched: matched, thread: thread}, _started) when matched > 0,
    do: "#{thread} has older messages than this page holds — read on with next_cursor"

  defp empty(%{header: %{count: 0, last_at: nil}, thread: thread}, started),
    do: never_posted(thread, started)

  defp empty(%{header: %{count: 0}, thread: thread}, started),
    do: "nothing kept on #{thread} — messages started at #{started}"

  defp empty(%{thread: thread}, started),
    do: "nothing on #{thread} matching that filter — messages started at #{started}"

  defp handle_line(line, zone) do
    present(%{
      handle: line.handle,
      last_send: Clock.format(line.last_send, zone),
      last_check: Clock.format(line.last_check, zone)
    })
  end

  # ─── Rendering ──────────────────────────────────────────────────────

  defp render(%Message{} = message, zone),
    do: %{
      id: message.id,
      handle: message.handle,
      at: Clock.format(message.at, zone),
      body: message.body
    }

  defp dropped(_thread, nil, _zone), do: nil

  defp dropped(thread, dropped_at, zone),
    do:
      "messages on #{thread} up to #{Clock.format(dropped_at, zone)} were dropped — " <>
        "the node keeps the newest #{@count_cap}"

  defp page(zone) do
    %{
      count: @page_count,
      bytes: @page_bytes,
      size: fn message -> message |> render(zone) |> JSON.encode!() |> byte_size() end
    }
  end

  defp started(state, zone), do: Clock.format(state.started_at, zone)

  defp never_posted(thread, started),
    do: "nothing on #{thread} since messages started at #{started}"

  # An answer carries no key whose only content is "nothing here".
  defp present(answer), do: Map.reject(answer, fn {_key, value} -> value in [nil, []] end)

  defp zone(%{zone: nil}), do: Context.time_zone()
  defp zone(%{zone: zone}), do: zone

  defp now, do: DateTime.truncate(DateTime.utc_now(), :second)
end
