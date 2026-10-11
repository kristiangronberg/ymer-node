defmodule YmerNode.MessagesTest do
  @moduledoc """
  Each case starts a process of its own under its own name and passes it to
  every call, so no case meets the application's process or another case's
  messages, and the module stays `async: true`. The node time zone is
  `Etc/UTC` here, so every time an answer carries ends in `Z` — except under
  "in a zone with summer time", whose cases start their process with
  `zone: "Europe/Helsinki"`.

  The bounds are the real ones, never smaller stand-ins: the count cap is
  reached with 10 001 sends, which take well under a second.
  """
  use ExUnit.Case, async: true

  alias YmerNode.Messages

  setup do
    server = :"messages_#{System.unique_integer([:positive])}"
    start_supervised!({Messages, name: server})
    %{server: server}
  end

  defp sent(server, handle, thread, bodies) do
    for body <- bodies do
      {:ok, answer} = Messages.send(handle, thread, body, server)
      answer
    end
  end

  describe "send/4" do
    test "answers the id, the thread and the time", %{server: server} do
      assert {:ok, %{id: 1, thread: "x", at: at}} = Messages.send("dev", "x", "ready", server)
      assert {:ok, _datetime, 0} = DateTime.from_iso8601(at)
    end

    test "accepts a body of exactly 8 KB", %{server: server} do
      assert {:ok, %{id: 1}} = Messages.send("dev", "x", String.duplicate("a", 8_192), server)
    end

    test "refuses a body over 8 KB with its size, and stores nothing", %{server: server} do
      body = String.duplicate("a", 8_193)

      assert {:error, {:body_too_large, detail}} = Messages.send("dev", "x", body, server)
      assert detail =~ "8193 bytes"

      assert {:ok, %{notice: "nothing on x since messages started at " <> _}} =
               Messages.check("test", "x", server)
    end

    test "counts the body cap in bytes, not characters", %{server: server} do
      body = String.duplicate("ä", 4_097)

      assert {:error, {:body_too_large, detail}} = Messages.send("dev", "x", body, server)
      assert detail =~ "8194 bytes"
    end

    test "refuses a handle or a thread over 512 bytes", %{server: server} do
      long = String.duplicate("n", 513)

      assert {:error, {:name_too_long, detail}} = Messages.send(long, "x", "hi", server)
      assert detail =~ "513 bytes"
      assert {:error, {:name_too_long, _detail}} = Messages.send("dev", long, "hi", server)
      assert {:error, {:name_too_long, _detail}} = Messages.check("dev", long, server)
      assert {:ok, _sent} = Messages.send("dev", String.duplicate("n", 512), "hi", server)
    end
  end

  describe "check/3" do
    test "returns another handle's messages once, and then says nothing is new",
         %{server: server} do
      {:ok, _sent} = Messages.send("dev", "x", "x1 is ready for testing", server)

      assert {:ok, %{thread: "x", messages: [%{handle: "dev", body: "x1 is ready for testing"}]}} =
               Messages.check("test", "x", server)

      assert {:ok, %{notice: notice}} = Messages.check("test", "x", server)
      assert notice =~ "nothing new on x since test's last check at "
      assert notice =~ "messages started at "
    end

    test "on a first check that finds only the handle's own messages, says nothing is new",
         %{server: server} do
      {:ok, _sent} = Messages.send("dev", "x", "hello", server)

      assert {:ok, %{notice: "nothing new on x for dev — messages started at " <> _}} =
               Messages.check("dev", "x", server)
    end

    @tag doc: """
         Guards the never-silent rule: a thread nothing was posted to — a
         misspelling, or a conversation a restart lost — must not read as "no
         reply yet". A failure means an empty answer lost its start time or the
         threads that do hold mail for the handle.
         """
    test "on a thread nothing was posted to, names the start and the threads with mail",
         %{server: server} do
      {:ok, _joined} = Messages.check("test", "x", server)
      {:ok, _sent} = Messages.send("dev", "x", "hello", server)

      assert {:ok, %{notice: notice, elsewhere: [%{thread: "x", unread: 1}]}} =
               Messages.check("test", "y-misspelt", server)

      assert notice =~ "nothing on y-misspelt since messages started at "
    end

    test "pages at 20 messages and says how many remain", %{server: server} do
      sent(server, "dev", "x", for(n <- 1..25, do: "#{n}"))

      assert {:ok, %{messages: messages, more_unread: 5}} = Messages.check("test", "x", server)
      assert length(messages) == 20
    end

    test "pages at 32 KB measured as each message is sent, JSON escapes included",
         %{server: server} do
      sent(server, "dev", "x", List.duplicate(String.duplicate(~s("), 4_000), 5))

      assert {:ok, %{messages: messages, more_unread: 1}} = Messages.check("test", "x", server)
      assert length(messages) == 4
    end

    @tag doc: """
         Pins the dropped notice's exact words, which name the newest message
         lost ("up to"). A failure that reads "before" means the notice was
         reworded to name the oldest message kept instead.
         """
    test "says what the count cap dropped, in the node's own words", %{server: server} do
      [%{at: first_at} | _rest] = sent(server, "dev", "x", for(n <- 1..10_001, do: "#{n}"))

      assert {:ok, %{messages: [%{body: "2"} | _rest], dropped: dropped}} =
               Messages.check("test", "x", server)

      assert dropped ==
               "messages on x up to #{first_at} were dropped — the node keeps the newest 10000"
    end

    test "with no thread, lists the threads with unread mail and moves no mark",
         %{server: server} do
      {:ok, _joined} = Messages.check("test", "x", server)
      {:ok, _sent} = Messages.send("dev", "x", "hello", server)

      assert {:ok, %{threads: [%{thread: "x", unread: 1}]}} = Messages.check("test", nil, server)
      assert {:ok, %{threads: [%{thread: "x", unread: 1}]}} = Messages.check("test", nil, server)
    end

    test "with no thread, for a handle with nothing unread anywhere, says so",
         %{server: server} do
      {:ok, _joined} = Messages.check("test", "x", server)

      assert {:ok, %{notice: "nothing new for test on any thread — messages started at " <> _}} =
               Messages.check("test", nil, server)
    end

    test "with no thread, for a handle that has joined nothing, points at the index",
         %{server: server} do
      assert {:ok, %{notice: notice}} = Messages.check("nobody", nil, server)
      assert notice =~ "read {} lists every thread"
    end
  end

  describe "read/2" do
    test "with no thread and no since, answers the thread index", %{server: server} do
      {:ok, _sent} = Messages.send("dev", "x", "hello", server)

      assert {:ok, %{started_at: _, threads: [%{thread: "x", count: 1, handles: ["dev"]}]}} =
               Messages.read(%{}, server)
    end

    test "leaves a thread only a check has joined without a last activity in the index",
         %{server: server} do
      {:ok, _joined} = Messages.check("test", "x", server)

      assert {:ok, %{threads: [row]}} = Messages.read(%{}, server)
      assert %{thread: "x", count: 0} = row
      refute Map.has_key?(row, :last_activity)
    end

    test "opens a thread's answer with its header, and moves no mark", %{server: server} do
      {:ok, _joined} = Messages.check("test", "x", server)
      {:ok, _sent} = Messages.send("dev", "x", "hello", server)

      assert {:ok, %{threads: [thread]}} = Messages.read(%{thread: "x", last: 1}, server)

      assert %{
               count: 1,
               handles: [%{handle: "dev", last_send: _}, %{handle: "test", last_check: _}],
               messages: [%{body: "hello"}]
             } = thread

      assert {:ok, %{messages: [%{body: "hello"}]}} = Messages.check("test", "x", server)
    end

    test "takes the newest ten by default and gives the cursor to read on with",
         %{server: server} do
      sent(server, "dev", "x", for(n <- 1..15, do: "#{n}"))

      assert {:ok, %{threads: [%{messages: messages}], next_cursor: 6}} =
               Messages.read(%{thread: "x"}, server)

      assert Enum.map(messages, & &1.id) == Enum.to_list(15..6//-1)
    end

    test "names a thread the process has never seen", %{server: server} do
      assert {:ok, %{threads: [%{thread: "nowhere", notice: notice}]}} =
               Messages.read(%{thread: ["nowhere"]}, server)

      assert notice =~ "since messages started at "
    end

    @tag doc: """
         Guards the never-silent rule for a read: after a restart, a waiting
         session's check makes the thread again, empty. A failure means a read
         of it shows the waiting handle and no word that messages started
         only at the restart.
         """
    test "says when messages started on a thread only a check has joined", %{server: server} do
      {:ok, _joined} = Messages.check("test", "x", server)

      assert {:ok, %{threads: [%{thread: "x", count: 0, handles: [_test], notice: notice}]}} =
               Messages.read(%{thread: "x"}, server)

      assert notice =~ "nothing on x since messages started at "
    end

    test "says when a named thread's filter matched nothing", %{server: server} do
      {:ok, _sent} = Messages.send("dev", "x", "hello", server)

      assert {:ok, %{threads: [%{thread: "x", count: 1, notice: notice}]}} =
               Messages.read(%{thread: "x", since: "2999-01-01T00:00:00Z"}, server)

      assert notice =~ "nothing on x matching that filter — messages started at "
    end

    test "says nothing is kept on a thread the count cap emptied, whatever the since",
         %{server: server} do
      {:ok, _sent} = Messages.send("dev", "x", "lost", server)
      sent(server, "dev", "y", for(n <- 1..10_000, do: "#{n}"))

      assert {:ok, %{threads: [%{thread: "x", count: 0, notice: notice}]}} =
               Messages.read(%{thread: "x", since: "2999-01-01T00:00:00Z"}, server)

      assert notice =~ "nothing kept on x — messages started at "
    end

    test "names the cursor when an all-thread read below it finds nothing",
         %{server: server} do
      {:ok, _sent} = Messages.send("dev", "x", "hello", server)

      assert {:ok, %{notice: "nothing before id 1 since " <> _}} =
               Messages.read(%{since: "PT1H", before: 1}, server)
    end

    test "says a thread the page went to other threads for has more to read on",
         %{server: server} do
      sent(server, "dev", "x", ["x1"])
      sent(server, "dev", "y", ["y1", "y2"])

      assert {:ok, %{threads: [x, %{messages: [%{body: "y2"}]}], next_cursor: 3}} =
               Messages.read(%{thread: ["x", "y"], last: 1}, server)

      assert x.notice == "x has older messages than this page holds — read on with next_cursor"
    end

    test "reads every thread since a span back from now", %{server: server} do
      {:ok, _sent} = Messages.send("dev", "x", "recent", server)

      assert {:ok, %{threads: [%{thread: "x", messages: [%{body: "recent"}]}]}} =
               Messages.read(%{since: "PT1H"}, server)

      assert {:ok, %{notice: "nothing since " <> _}} =
               Messages.read(%{since: "2999-01-01T00:00:00"}, server)
    end

    test "refuses last or before with neither a thread nor a since", %{server: server} do
      assert {:error, {:read_needs_thread, detail}} = Messages.read(%{last: 3}, server)
      assert detail == "read was given last 3 but neither thread nor since"

      assert {:error, {:read_needs_thread, _detail}} = Messages.read(%{before: 5}, server)
    end

    test "refuses a since that is neither a span nor a date-time", %{server: server} do
      assert {:error, {:invalid_since, "yesterday is neither " <> _}} =
               Messages.read(%{since: "yesterday"}, server)
    end
  end

  describe "in a zone with summer time" do
    setup do
      server = :"messages_helsinki_#{System.unique_integer([:positive])}"
      start_supervised!({Messages, name: server, zone: "Europe/Helsinki"}, id: server)
      %{server: server}
    end

    test "renders every time with the zone's offset", %{server: server} do
      assert {:ok, %{at: at}} = Messages.send("dev", "x", "hello", server)
      assert at =~ ~r/\+0[23]:00$/
    end

    test "reads an offset-less since in the zone, and an offset as given", %{server: server} do
      for {given, rendered} <- [
            {"2026-01-15T09:00:00", "2026-01-15T09:00:00+02:00"},
            {"2026-01-15T09:00:00Z", "2026-01-15T11:00:00+02:00"},
            {"2026-01-15T09:00:00+03:00", "2026-01-15T08:00:00+02:00"}
          ] do
        assert {:ok, %{notice: "nothing since " <> notice}} =
                 Messages.read(%{since: given}, server)

        assert String.starts_with?(notice, rendered <> " — messages started at "), given
      end
    end

    test "refuses a since the zone's clock never shows", %{server: server} do
      assert {:error, {:invalid_since, detail}} =
               Messages.read(%{since: "2027-03-28T03:30:00"}, server)

      assert detail =~ "never shows on a clock in Europe/Helsinki"
    end
  end
end
