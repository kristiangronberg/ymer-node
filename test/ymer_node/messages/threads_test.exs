defmodule YmerNode.Messages.ThreadsTest do
  use ExUnit.Case, async: true

  alias YmerNode.Messages.Threads

  @now ~U[2026-10-11 09:00:00Z]
  @page %{count: 20, bytes: 32_768, size: &__MODULE__.body_size/1}

  def body_size(message), do: byte_size(message.body)

  defp at(seconds), do: DateTime.add(@now, seconds, :second)

  defp posted(state, posts) do
    Enum.reduce(posts, state, fn {handle, thread, body}, acc ->
      {_message, acc} = Threads.post(acc, handle, thread, body, @now)
      acc
    end)
  end

  defp bodies(messages), do: Enum.map(messages, & &1.body)

  # Reads on through next_cursor until there is none, newest first.
  defp walk(state, threads, filters) do
    %{threads: answers, cursor: cursor} = Threads.read(state, threads, filters, @page)
    returned = answers |> Enum.flat_map(& &1.messages) |> Enum.sort_by(& &1.id, :desc)

    case cursor do
      nil -> bodies(returned)
      cursor -> bodies(returned) ++ walk(state, threads, %{filters | before: cursor})
    end
  end

  describe "post/5" do
    test "numbers messages across threads and stamps the time and the handle" do
      state = Threads.new(10)
      {first, state} = Threads.post(state, "a/dev", "x", "one", @now)
      {second, _state} = Threads.post(state, "b/test", "y", "two", at(1))

      assert %{id: 1, thread: "x", handle: "a/dev", at: @now, body: "one"} = first
      assert %{id: 2, thread: "y", handle: "b/test"} = second
    end

    test "drops the oldest message past the count cap, whichever thread holds it" do
      state =
        Threads.new(3)
        |> posted([{"a", "x", "1"}, {"a", "y", "2"}, {"a", "x", "3"}, {"a", "y", "4"}])

      assert %{count: 1} = Threads.header(state, "x")
      assert %{count: 2} = Threads.header(state, "y")
    end

    test "keeps its own copy of each string, never the binary it was cut from" do
      request = String.duplicate("r", 100_000) <> "x-dev" <> "x" <> "one"

      <<_::binary-size(100_000), handle::binary-size(5), thread::binary-size(1), body::binary>> =
        request

      {message, _state} = Threads.post(Threads.new(10), handle, thread, body, @now)

      for kept <- [message.handle, message.thread, message.body] do
        assert :binary.referenced_byte_size(kept) == byte_size(kept)
      end
    end
  end

  describe "check/5" do
    test "returns what is new oldest first, leaves out its own, and moves the mark" do
      state =
        Threads.new(10) |> posted([{"dev", "x", "1"}, {"test", "x", "2"}, {"dev", "x", "3"}])

      {answer, state} = Threads.check(state, "test", "x", at(5), @page)

      assert bodies(answer.messages) == ["1", "3"]
      assert answer.more == 0
      assert answer.last_check == nil
      assert answer.posted?

      {again, _state} = Threads.check(state, "test", "x", at(6), @page)

      assert again.messages == []
      assert again.last_check == at(5)
    end

    test "pages by count, says how many remain, and the next check takes the next page" do
      state = Threads.new(10) |> posted(for n <- 1..5, do: {"dev", "x", "#{n}"})
      page = %{@page | count: 2}

      {first, state} = Threads.check(state, "test", "x", @now, page)
      {second, _state} = Threads.check(state, "test", "x", @now, page)

      assert {bodies(first.messages), first.more} == {["1", "2"], 3}
      assert {bodies(second.messages), second.more} == {["3", "4"], 1}
    end

    test "pages by bytes, but always returns at least one message" do
      state = Threads.new(10) |> posted([{"dev", "x", "aaaa"}, {"dev", "x", "bbbb"}])

      {answer, _state} = Threads.check(state, "test", "x", @now, %{@page | bytes: 3})

      assert bodies(answer.messages) == ["aaaa"]
      assert answer.more == 1
    end

    test "joins a thread nobody has posted to, so the header shows the handle waiting" do
      {answer, state} = Threads.check(Threads.new(10), "test", "x", @now, @page)

      refute answer.posted?

      assert %{count: 0, handles: [%{handle: "test", last_check: @now}]} =
               Threads.header(state, "x")
    end

    test "says when messages were dropped before the handle's read mark" do
      state = Threads.new(2) |> posted([{"dev", "x", "1"}, {"dev", "x", "2"}, {"dev", "x", "3"}])

      {answer, state} = Threads.check(state, "test", "x", @now, @page)

      {again, _state} =
        Threads.check(posted(state, [{"dev", "x", "4"}]), "test", "x", @now, @page)

      assert bodies(answer.messages) == ["2", "3"]
      assert answer.dropped_at == @now
      assert again.dropped_at == nil
    end

    test "says the drop once even when the thread keeps nothing past the read mark" do
      state = Threads.new(2) |> posted([{"dev", "x", "1"}])
      {_answer, state} = Threads.check(state, "test", "x", @now, @page)
      state = posted(state, [{"dev", "x", "2"}, {"dev", "y", "a"}, {"dev", "y", "b"}])

      {first, state} = Threads.check(state, "test", "x", @now, @page)
      {second, _state} = Threads.check(state, "test", "x", @now, @page)

      assert {first.messages, first.dropped_at} == {[], @now}
      assert second.dropped_at == nil
    end
  end

  describe "unread/2 and joined?/2" do
    test "lists the threads the handle took part in that hold unread, never its own" do
      state =
        Threads.new(10)
        |> posted([{"test", "x", "hello"}, {"dev", "x", "1"}, {"dev", "x", "2"}])
        |> posted([{"dev", "y", "elsewhere"}, {"test", "z", "mine"}])

      assert Threads.unread(state, "test") == [%{thread: "x", unread: 2}]
      assert Threads.joined?(state, "test")
      refute Threads.joined?(state, "nobody")
    end
  end

  describe "index/1" do
    test "lists every thread, the most recently active first" do
      state = Threads.new(10)
      {_message, state} = Threads.post(state, "dev", "old", "1", @now)
      {_message, state} = Threads.post(state, "test", "new", "2", at(60))
      {_answer, state} = Threads.check(state, "qa", "quiet", at(90), @page)

      assert [
               %{thread: "new", count: 1, last_at: _, handles: ["test"]},
               %{thread: "old", count: 1, handles: ["dev"]},
               %{thread: "quiet", count: 0, last_at: nil, handles: ["qa"]}
             ] = Threads.index(state)
    end
  end

  describe "read/4" do
    test "answers the newest messages first with the header, and moves no mark" do
      state =
        Threads.new(10) |> posted([{"dev", "x", "1"}, {"test", "x", "2"}, {"dev", "x", "3"}])

      filters = %{last: 2, before: nil, since: nil}

      %{threads: [thread], cursor: cursor} = Threads.read(state, ["x"], filters, @page)

      assert bodies(thread.messages) == ["3", "2"]
      assert %{count: 3, handles: [%{handle: "dev"}, %{handle: "test"}]} = thread.header
      assert cursor == 2

      {answer, _state} = Threads.check(state, "test", "x", @now, @page)
      assert bodies(answer.messages) == ["1", "3"]
    end

    test "the cursor passed back as before reads on into older messages" do
      state = Threads.new(10) |> posted(for n <- 1..3, do: {"dev", "x", "#{n}"})

      %{threads: [thread], cursor: cursor} =
        Threads.read(state, ["x"], %{last: 2, before: nil, since: nil}, @page)

      %{threads: [older], cursor: none} =
        Threads.read(state, ["x"], %{last: 2, before: cursor, since: nil}, @page)

      assert bodies(thread.messages) == ["3", "2"]
      assert bodies(older.messages) == ["1"]
      assert none == nil
    end

    test "merges several threads newest first and cuts the page from the top" do
      state =
        Threads.new(10)
        |> posted([
          {"dev", "x", "x1"},
          {"dev", "y", "y1"},
          {"dev", "x", "x2"},
          {"dev", "y", "y2"}
        ])

      %{threads: [x, y], cursor: cursor} =
        Threads.read(state, ["x", "y"], %{last: 10, before: nil, since: nil}, %{@page | count: 3})

      assert bodies(x.messages) == ["x2"]
      assert bodies(y.messages) == ["y2", "y1"]
      assert cursor == 2
    end

    @tag doc: """
         A failure means a walk to the end of the cursor no longer returns
         every message exactly once. Look first for a `last` taken thread by
         thread: it leaves a busy thread's cut messages above the oldest id
         returned, and paging on from that id skips them for good.
         """
    test "takes last across the named threads, so the cursor walks every message once" do
      state =
        Threads.new(10)
        |> posted([{"dev", "x", "x1"}, {"dev", "x", "x2"}])
        |> posted([{"dev", "y", "y1"}, {"dev", "y", "y2"}, {"dev", "y", "y3"}])

      assert walk(state, ["x", "y"], %{last: 1, before: nil, since: nil}) ==
               ["y3", "y2", "y1", "x2", "x1"]
    end

    test "walks every thread since a time to the end, each message once" do
      {_old, state} = Threads.post(Threads.new(10), "dev", "x", "before", @now)

      state =
        Enum.reduce(1..6, state, fn n, acc ->
          {_message, acc} =
            Threads.post(acc, "dev", if(n <= 3, do: "x", else: "y"), "#{n}", at(60))

          acc
        end)

      assert walk(state, :all, %{last: 1, before: nil, since: at(30)}) ==
               ["6", "5", "4", "3", "2", "1"]
    end

    test "counts each thread's matching messages, whether or not the page kept any" do
      state = Threads.new(10) |> posted([{"dev", "x", "x1"}, {"dev", "y", "y1"}])

      %{threads: [x, y]} =
        Threads.read(state, ["x", "y"], %{last: 1, before: nil, since: nil}, @page)

      %{threads: [later]} =
        Threads.read(state, ["x"], %{last: 1, before: nil, since: at(60)}, @page)

      assert {x.messages, x.matched} == {[], 1}
      assert {bodies(y.messages), y.matched} == {["y1"], 1}
      assert {later.messages, later.matched} == {[], 0}
    end

    test "under :all answers only the threads with a message since the time given" do
      state = Threads.new(10)
      {_message, state} = Threads.post(state, "dev", "old", "1", @now)
      {_message, state} = Threads.post(state, "dev", "new", "2", at(3600))

      %{threads: [thread]} =
        Threads.read(state, :all, %{last: 10, before: nil, since: at(60)}, @page)

      assert thread.thread == "new"
    end

    test "answers a thread the process has never seen with no header" do
      %{threads: [thread], cursor: nil} =
        Threads.read(Threads.new(10), ["nowhere"], %{last: 10, before: nil, since: nil}, @page)

      assert %{thread: "nowhere", header: nil, messages: []} = thread
    end

    test "says messages were dropped only once the read reaches the oldest one kept" do
      state = Threads.new(3) |> posted(for n <- 1..5, do: {"dev", "x", "#{n}"})

      %{threads: [newest]} =
        Threads.read(state, ["x"], %{last: 1, before: nil, since: nil}, @page)

      %{threads: [whole]} =
        Threads.read(state, ["x"], %{last: 10, before: nil, since: nil}, @page)

      assert newest.dropped_at == nil
      assert bodies(whole.messages) == ["5", "4", "3"]
      assert whole.dropped_at == @now
    end

    test "answers a thread the cap emptied under :all, with its drop" do
      state = Threads.new(2) |> posted([{"dev", "x", "1"}, {"dev", "y", "2"}, {"dev", "y", "3"}])

      %{threads: answers} =
        Threads.read(state, :all, %{last: 10, before: nil, since: @now}, @page)

      assert [
               %{thread: "x", messages: [], dropped_at: @now},
               %{thread: "y", dropped_at: nil} = kept
             ] =
               Enum.sort_by(answers, & &1.thread)

      assert bodies(kept.messages) == ["3", "2"]
    end
  end
end
