defmodule YmerNode.Mcp.McpServer do
  @moduledoc """
  The instructions the node hands every MCP client at connect.

  Home for this text rather than the mount itself, because the mount's job is
  wiring and this is prose with its own obligations. Two of them are worth
  stating, since neither is visible from the string:

  The text must stay inside a **2KB budget** — Claude Code truncates server
  instructions at 2048 bytes, a cliff rather than a warning, and a truncated
  paragraph is worse than an absent one. `YmerNode.McpTest` gates the size.

  It must **name ymer as the other half of one product**. A client that reaches
  this node learns nothing about ymer from the wire surface — two servers look
  like two products unless one of them says otherwise. The same duty runs the
  other way from ymer's own instructions. There is no shared source between the
  two texts and there cannot be one: the repositories are standalone, so the pair
  is kept in step by convention and by review, and drift is a review finding
  rather than a build failure.
  """

  @doc """
  The connect-time instructions, as served. Kept as a single literal so the byte
  budget is a property of one readable thing.
  """
  def instructions do
    """
    Ymer Node is your local capability node: a private SQL notebook, a registry
    of references to where knowledge lives, and the scripts it accepts. All of
    it stays on this machine.

    The node self-documents through the help tool: help {} lists every tool and
    action; help {tool: "notebook"} documents one tool; add action: for full
    parameter schemas, examples, and notes. Never guess action or parameter
    names: look them up with help first, and again when a call fails or
    surprises you.

    When to reach for each tool:
    - notebook — your own store: create and evolve your own tables, keep
      documents with vector embeddings, and run KNN search. execute = writes
      and DDL, query = read-only SELECT. The same tool saves and rolls the
      store back: create, list, restore. Reach for a backup before anything
      destructive, and whenever the user asks.
    - references — the registry of where knowledge lives: find returns pointers,
      each with a fetch recipe where one is derivable, and you make that call
      yourself. Store pointers and routing notes, never copies of what they
      point at. Until registry sync lands, a reference added here lives only on
      this machine.
    - scripts — Elixir modules this node has accepted, for systems with no
      built-in support. Read scripts guide before writing one, and scripts info
      for each promised package you use; describe before you run: an action's
      write mark says whether it changes anything outside this machine.
      script_author writes them.

    Ymer Node and ymer are two halves of one product. ymer holds tasks,
    projects, docs and memories — the coordination every client can reach.
    This node holds what is local to this machine. Both are worth connecting
    and neither replaces the other: anything worth keeping across machines
    belongs in ymer, anything private to this machine belongs here.

    Local capability never depends on ymer being reachable. If ymer is down or
    this node is not signed in, the notebook, the registry and the scripts still
    answer — say so rather than treating it as an outage.
    """
  end
end
