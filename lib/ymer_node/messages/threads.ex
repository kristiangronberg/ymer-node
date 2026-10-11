defmodule YmerNode.Messages.Threads do
  @moduledoc """
  What `YmerNode.Messages` holds — every kept message by thread, and each
  handle's read mark, last send and last check on every thread it has taken
  part in — as a value, with the functions that decide what a send, a check and
  a read do to it.

  The process is the clock around this module: every function here is handed
  the time it runs at, and the page it answers within, so each rule below is a
  deterministic function a test drives with a count cap of three rather than
  ten thousand.

  ## Ids and the count cap

  Every message takes the next id across all threads, so ids order the whole
  history and a read's cursor needs no thread beside it. Past the count cap the
  oldest message is dropped, whichever thread holds it. The thread remembers the
  newest message it lost, and that is how a check whose read mark sits before
  it, or a read that reaches back to the oldest message kept, can say that
  messages were dropped.

  ## Read marks

  Each handle's [*read mark*](docs/glossary.md#read-mark) on a thread is kept
  here as a message id. `check/5` returns what lies past it, oldest first,
  leaves out the handle's own
  messages, and moves the mark past everything it walked — its own messages
  among them, so they never count as unread. A check also joins the thread: a
  thread nobody has posted to yet exists from its first check, so a session
  waiting on it shows in the thread's header before anything arrives.

  ## Pages

  A page stops at its message count or its byte budget, whichever comes first,
  and always holds at least one message, so paging always moves. What a
  message weighs is the page's `size` function — `YmerNode.Messages` measures
  each message as it will be sent.

  `read/4` moves no mark. It merges the named threads' messages newest first,
  takes the newest `last` of them across all those threads together, and cuts
  the page from the top. Every message `last` or the page leaves out is older
  than every message kept, so the oldest id returned is the cursor to pass back
  as `before`, and it is given while any named thread keeps an older message.
  That is why `last` is never taken thread by thread: a busy thread's cut
  messages would then sit above a quieter thread's oldest returned one, and a
  cursor below them would skip them for good.
  """

  alias YmerNode.Messages.Message

  @type t :: %__MODULE__{}

  @typedoc "How many messages a page holds, how many bytes, and what one weighs."
  @type page :: %{
          count: pos_integer(),
          bytes: pos_integer(),
          size: (Message.t() -> non_neg_integer())
        }

  defstruct cap: 10_000, next_id: 1, count: 0, order: :queue.new(), threads: %{}

  @thread %{
    messages: :queue.new(),
    count: 0,
    last_at: nil,
    dropped_at: nil,
    dropped_through: 0,
    handles: %{}
  }

  @handle %{read_through: 0, last_send: nil, last_check: nil}

  def new(cap) when is_integer(cap) and cap > 0, do: %__MODULE__{cap: cap}

  @doc """
  Posts `body` to `thread` as `handle` at `now`. Returns the message and the
  state it is kept in — past the count cap, without the oldest message held.
  """
  def post(%__MODULE__{} = state, handle, thread, body, %DateTime{} = now)
      when is_binary(handle) and is_binary(thread) and is_binary(body) do
    # Each string is copied, so a kept message never holds alive the request
    # binary it was cut from.
    message = %Message{
      id: state.next_id,
      thread: :binary.copy(thread),
      handle: :binary.copy(handle),
      at: now,
      body: :binary.copy(body)
    }

    entry =
      state.threads
      |> Map.get(message.thread, @thread)
      |> Map.update!(:messages, &:queue.in(message, &1))
      |> Map.update!(:count, &(&1 + 1))
      |> Map.put(:last_at, now)
      |> touch(message.handle, :last_send, now)

    state = %{
      state
      | next_id: message.id + 1,
        count: state.count + 1,
        order: :queue.in({message.id, message.thread}, state.order),
        threads: Map.put(state.threads, message.thread, entry)
    }

    {message, evict(state)}
  end

  @doc """
  Checks `thread` as `handle` at `now`, within `page`. Returns the answer and
  the state with the handle's read mark moved.

  The answer's `messages` are oldest first; `more` counts the unread left past
  the page; `last_check` is the handle's previous check of this thread, `nil`
  on its first; `posted?` says whether anything was ever posted to the thread;
  and `dropped_at` is the time of the newest message the thread lost to the
  count cap, given only when the handle's read mark sits before it.
  """
  def check(%__MODULE__{} = state, handle, thread, %DateTime{} = now, page)
      when is_binary(handle) and is_binary(thread) and is_map(page) do
    entry = Map.get(state.threads, thread, @thread)
    mark = Map.get(entry.handles, handle, @handle)
    pending = entry.messages |> :queue.to_list() |> Enum.filter(&(&1.id > mark.read_through))
    {taken, through} = take(pending, handle, page, {[], 0, mark.read_through})

    answer = %{
      messages: taken,
      more: unread_past(pending, handle, through),
      last_check: mark.last_check,
      posted?: entry.last_at != nil,
      dropped_at: if(mark.read_through < entry.dropped_through, do: entry.dropped_at)
    }

    # Every kept message lies past what the thread dropped, so moving the mark
    # past the drop skips nothing unread, and the drop is said once.
    marked = %{mark | read_through: max(through, entry.dropped_through), last_check: now}
    entry = %{entry | handles: Map.put(entry.handles, handle, marked)}

    {answer, %{state | threads: Map.put(state.threads, thread, entry)}}
  end

  @doc """
  The threads `handle` has taken part in that hold messages it has not read,
  each with the count of them, by thread. Its own messages are never unread.
  """
  def unread(%__MODULE__{} = state, handle) when is_binary(handle) do
    state.threads
    |> Enum.filter(fn {_thread, entry} -> Map.has_key?(entry.handles, handle) end)
    |> Enum.map(fn {thread, entry} -> %{thread: thread, unread: unread_count(entry, handle)} end)
    |> Enum.filter(&(&1.unread > 0))
    |> Enum.sort_by(& &1.thread)
  end

  @doc "Whether `handle` has sent on, or checked, any thread."
  def joined?(%__MODULE__{} = state, handle) when is_binary(handle) do
    Enum.any?(state.threads, fn {_thread, entry} -> Map.has_key?(entry.handles, handle) end)
  end

  @doc """
  One row per thread — its message count, last activity and handles — the
  most recently active first, threads nobody has posted to last.
  """
  def index(%__MODULE__{} = state) do
    state.threads
    |> Enum.map(fn {thread, entry} ->
      %{
        thread: thread,
        count: entry.count,
        last_at: entry.last_at,
        handles: entry.handles |> Map.keys() |> Enum.sort()
      }
    end)
    |> Enum.sort_by(&{recency(&1.last_at), &1.thread})
  end

  @doc """
  Reads `threads` — a list of names, or `:all` for every thread — within
  `filters` and `page`, moving no mark.

  `filters` holds `last`, the newest messages taken across the named threads
  together; `before`, an id every message returned lies below, or `nil`; and
  `since`, a UTC time every message returned was posted at or after, or `nil`.
  Each thread's answer carries its header — `nil` for a thread the process has
  never seen — its messages newest first; `matched`, how many of the messages
  it keeps fall within `before` and `since`, so an answer with none can say
  whether the filter or the page left them out; and `dropped_at` when the read
  reached back to the oldest message the thread keeps and the count cap had
  dropped messages before it. Under `:all` only the threads with a message to
  return, or a drop to report, answer.
  """
  def read(%__MODULE__{} = state, threads, %{last: last, before: before, since: since}, page)
      when (threads == :all or is_list(threads)) and is_integer(last) and last > 0 and
             is_map(page) do
    names = names(state, threads)
    matches = Map.new(names, &{&1, matching(state, &1, before, since)})
    merged = matches |> Map.values() |> Enum.concat() |> Enum.sort_by(& &1.id, :desc)
    returned = merged |> Enum.take(last) |> cut(page, {[], 0})
    oldest = returned |> List.last() |> id()

    answers =
      names
      |> Enum.map(&thread_read(state, &1, Map.fetch!(matches, &1), returned, {before, since}))
      |> Enum.reject(&(threads == :all and &1.messages == [] and &1.dropped_at == nil))

    # `returned` is a newest-first prefix of `merged`, so an older match
    # remains exactly when `merged` holds more than was returned.
    %{threads: answers, cursor: if(length(merged) > length(returned), do: oldest)}
  end

  @doc """
  A thread's header: its message count, last activity, and each handle with
  its last send and last check, by handle — `nil` for a thread the process has
  never seen.
  """
  def header(%__MODULE__{} = state, thread) when is_binary(thread) do
    case Map.fetch(state.threads, thread) do
      {:ok, entry} ->
        %{
          count: entry.count,
          last_at: entry.last_at,
          handles:
            entry.handles
            |> Enum.map(fn {handle, mark} ->
              %{handle: handle, last_send: mark.last_send, last_check: mark.last_check}
            end)
            |> Enum.sort_by(& &1.handle)
        }

      :error ->
        nil
    end
  end

  # ─── The count cap ──────────────────────────────────────────────────

  defp evict(%__MODULE__{count: count, cap: cap} = state) when count <= cap, do: state

  defp evict(state) do
    {{:value, {_id, thread}}, order} = :queue.out(state.order)
    entry = Map.fetch!(state.threads, thread)
    {{:value, dropped}, messages} = :queue.out(entry.messages)

    entry = %{
      entry
      | messages: messages,
        count: entry.count - 1,
        dropped_at: dropped.at,
        dropped_through: dropped.id
    }

    evict(%{
      state
      | order: order,
        count: state.count - 1,
        threads: Map.put(state.threads, thread, entry)
    })
  end

  # ─── Checks ─────────────────────────────────────────────────────────

  # Walks the unread oldest first: the handle's own messages are passed over
  # and move the mark, and the walk stops at the first message the page has no
  # room for.
  defp take([], _handle, _page, {taken, _bytes, through}), do: {Enum.reverse(taken), through}

  defp take([%Message{handle: handle} = own | rest], handle, page, {taken, bytes, _through}),
    do: take(rest, handle, page, {taken, bytes, own.id})

  defp take([message | rest], handle, page, {taken, bytes, through}) do
    weight = bytes + page.size.(message)

    if fits?(taken, weight, page),
      do: take(rest, handle, page, {[message | taken], weight, message.id}),
      else: {Enum.reverse(taken), through}
  end

  defp fits?([], _bytes, _page), do: true
  defp fits?(taken, bytes, page), do: length(taken) < page.count and bytes <= page.bytes

  defp unread_count(entry, handle) do
    mark = Map.fetch!(entry.handles, handle)
    entry.messages |> :queue.to_list() |> unread_past(handle, mark.read_through)
  end

  defp unread_past(messages, handle, through),
    do: Enum.count(messages, &(&1.id > through and &1.handle != handle))

  defp touch(entry, handle, field, now) do
    mark = entry.handles |> Map.get(handle, @handle) |> Map.put(field, now)
    %{entry | handles: Map.put(entry.handles, handle, mark)}
  end

  # ─── Reads ──────────────────────────────────────────────────────────

  defp names(state, :all), do: state.threads |> Map.keys() |> Enum.sort()
  defp names(_state, threads), do: Enum.uniq(threads)

  defp matching(state, thread, before, since),
    do: state |> kept(thread) |> Enum.filter(&(below?(&1, before) and since?(&1, since)))

  defp cut([], _page, {kept, _bytes}), do: Enum.reverse(kept)

  defp cut([message | rest], page, {kept, bytes}) do
    weight = bytes + page.size.(message)

    if fits?(kept, weight, page),
      do: cut(rest, page, {[message | kept], weight}),
      else: Enum.reverse(kept)
  end

  defp thread_read(state, thread, matched, returned, {before, since}) do
    messages = Enum.filter(returned, &(&1.thread == thread))
    entry = Map.get(state.threads, thread)
    bound = messages |> List.last() |> id() |> Kernel.||(before)

    %{
      thread: thread,
      header: header(state, thread),
      messages: messages,
      matched: length(matched),
      dropped_at: dropped_at(entry, matched, bound, since)
    }
  end

  defp dropped_at(nil, _matched, _bound, _since), do: nil
  defp dropped_at(%{dropped_at: nil}, _matched, _bound, _since), do: nil

  # `bound` never lies above `before`, so a match below it is a kept message
  # below it that the filters let through.
  defp dropped_at(entry, matched, bound, since) do
    reached? = not Enum.any?(matched, &below?(&1, bound))
    in_range? = since == nil or DateTime.compare(since, entry.dropped_at) != :gt

    if reached? and in_range?, do: entry.dropped_at
  end

  defp kept(state, thread) do
    case Map.fetch(state.threads, thread) do
      {:ok, entry} -> :queue.to_list(entry.messages)
      :error -> []
    end
  end

  defp below?(_message, nil), do: true
  defp below?(message, before), do: message.id < before

  defp since?(_message, nil), do: true
  defp since?(message, since), do: DateTime.compare(message.at, since) != :lt

  defp id(nil), do: nil
  defp id(%Message{id: id}), do: id

  defp recency(nil), do: 0
  defp recency(at), do: -DateTime.to_unix(at)
end
