defmodule YmerNode.Mcp.Tools.Messages.Schemas do
  @moduledoc """
  Action schemas for the `messages` tool. The `notes` surface through the `help`
  tool and are the worker-facing contract: what a handle and a thread are, what
  a check takes away and a read does not, and how a page ends.

  The body carries no `maxLength`: the cap is in bytes, and the context refuses
  an oversized body with where to put the content instead. A handle or a
  thread name carries one of 128 characters; the context refuses one over 512
  bytes, which no name the gate lets through reaches, for a call that never
  meets the gate.
  """

  @name_length 128

  @as %{
    "type" => "string",
    "description" =>
      "Your handle — a name you choose for yourself and keep for the conversation, " <>
        "by convention <client>/<short role>, the client being the application you " <>
        "run in. The node keeps one read mark per handle and thread.",
    "minLength" => 1,
    "maxLength" => @name_length,
    "examples" => ["claude_code/x-dev", "cowork/x-test"]
  }

  @thread %{
    "type" => "string",
    "description" =>
      "The thread — a key both sides know before either session exists, such as a " <>
        "task's name or a table/row reference. Compared, never interpreted.",
    "minLength" => 1,
    "maxLength" => @name_length,
    "examples" => ["session-messages", "tasks/42"]
  }

  @body %{
    "type" => "string",
    "description" =>
      "What you have to say, 8 KB at most. Anything longer goes in a file or a " <>
        "notebook row, and the message says where.",
    "minLength" => 1
  }

  @threads %{
    "type" => ["string", "array"],
    "description" =>
      "One thread, or a list of them. Left out, every thread from since on — or, " <>
        "with no since either, the thread index.",
    "minLength" => 1,
    "maxLength" => @name_length,
    "items" => %{"type" => "string", "minLength" => 1, "maxLength" => @name_length},
    "minItems" => 1,
    "maxItems" => 20
  }

  @last %{
    "type" => "integer",
    "description" =>
      "The newest messages taken, across all the threads read together " <>
        "(default 10, max 20).",
    "minimum" => 1,
    "maximum" => 20
  }

  @before %{
    "type" => "integer",
    "description" => "Only messages older than this id — a previous answer's next_cursor.",
    "minimum" => 1
  }

  @since %{
    "type" => "string",
    "description" =>
      "Only messages from this time on: an ISO-8601 span back from now (PT1H, P1D), " <>
        "or a date-time — with an offset it means exactly that, without one it is read " <>
        "in the node's time zone.",
    "minLength" => 1,
    "examples" => ["PT1H", "2026-10-11T09:00:00"]
  }

  @schemas %{
    send: %{
      description: "Send a message to a thread",
      properties: %{"as" => @as, "thread" => @thread, "body" => @body},
      required: ["as", "thread", "body"],
      defaults: %{},
      notes:
        "Whoever reads the thread sees it; no message is addressed to anyone. The " <>
          "answer carries the message's id and time. A body over 8 KB is refused, never " <>
          "cut. Messages are held in memory by the node: a restart loses them.",
      related: ["check", "read"]
    },
    check: %{
      description: "What is new for your handle",
      properties: %{"as" => @as, "thread" => @thread},
      required: ["as"],
      defaults: %{},
      notes:
        "With a thread: what is new there since your last check, oldest first, never " <>
          "your own messages, and your read mark moves past what it returns — checking " <>
          "a thread by name is how you join it. A page holds at most 20 messages and " <>
          "32 KB; more_unread says to check again. Without a thread: the threads you " <>
          "have taken part in that hold unread messages, with counts; no mark moves. " <>
          "An answer that finds nothing says when messages started, so a conversation " <>
          "a restart lost does not read as no reply yet.",
      related: ["send", "read"]
    },
    read: %{
      description: "Look at threads without moving any read mark",
      properties: %{
        "thread" => @threads,
        "last" => @last,
        "before" => @before,
        "since" => @since
      },
      required: [],
      defaults: %{},
      notes:
        "Nothing: the thread index — each thread's count, last activity and handles. " <>
          "A thread or a list: each opens with its header — count, last activity, every " <>
          "handle with its last send and last check — then its share of the newest " <>
          "messages across them, newest first; a thread with none says why. since " <>
          "alone: every thread's messages from then on. last and before page through " <>
          "messages, so they need a thread or since. A page holds at most 20 messages " <>
          "and 32 KB; next_cursor, while older messages remain, is the before to read " <>
          "on with. read never takes a message from anyone: look with read, then check " <>
          "to take.",
      related: ["check", "send"]
    }
  }

  def all, do: @schemas
end
