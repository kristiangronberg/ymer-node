defmodule YmerNode.Mcp do
  @moduledoc """
  The MCP mount — the node's entire external surface.

  The tool list is declared here and nowhere else, and it is read at this module's
  compile: a tool whose action schemas are malformed fails the build rather than
  the first request. That is also why the list is written out literally instead of
  read from configuration — naming the modules here is what records the
  compile-time dependency that keeps the check from going stale.

  ## Loopback is the security model

  `/mcp` carries no authentication. The compensating control is that the node is
  not reachable from the network: `ip/0` defaults to loopback, so the node binds
  `127.0.0.1` and nothing off-box can reach it.

  A node run in a container cannot keep that pin: a process bound to loopback
  inside a container is unreachable through a published port, so whoever runs it
  there widens the bind *within the container's own network namespace*, and the
  pin moves to the **host publish**. That publish must then carry the
  `127.0.0.1:` prefix itself — a `-p 8012:8012` **without** it publishes on every
  interface and exposes an unauthenticated SQL surface to the LAN.

  Widening the bind is a committed configuration, `config :ymer_node,
  YmerNode.Mcp, :ip`, and nothing in `ymer_node` widens it: the node reads that
  key from the application environment alone, and no variable of its own turns
  it on. The configuration that runs the node must not fill the key from the
  environment either, or a variable set at start would be enough to widen it.

  Widening either layer without adding authentication first is the mistake both
  paragraphs exist to prevent. **Scripts do not widen either layer, and they are
  not bounded by them**: an accepted script runs with the node's own permissions
  and reaches whatever this process can reach, so the boundary there is which
  scripts are accepted rather than which interface the node binds. `YmerNode`'s
  `## Scripts` section states it.

  Signing in to ymer is a different axis entirely — it
  proves the install is yours; it does not gate local calls, and no local call
  consults it.
  """
  # Aliased ahead of `use` rather than after it, against the usual module layout:
  # the router's options are evaluated in this module's context at compile time,
  # so an alias written below the `use` line would not be in scope for them.
  alias YmerNode.Mcp.McpServer

  use Wymcp.Router,
    tools: [
      YmerNode.Mcp.Tools.Messages,
      YmerNode.Mcp.Tools.Notebook,
      YmerNode.Mcp.Tools.References,
      YmerNode.Mcp.Tools.Schedules,
      YmerNode.Mcp.Tools.ScriptAuthor,
      YmerNode.Mcp.Tools.Scripts
    ],
    instructions: McpServer.instructions(),
    server_info: %{
      title: "Ymer Node",
      description:
        "Local capability for LLM workers: a private SQL notebook with vector " <>
          "search, a registry of pointers at where knowledge lives with a cache of " <>
          "what they say, and the " <>
          "scripts this node has accepted. All of it stays on this machine. " <>
          "The local half of Ymer."
    }

  # ─── Runtime configuration ──────────────────────────────────────────

  @doc "TCP port the node listens on (`config :ymer_node, YmerNode.Mcp, :port`)."
  def port do
    :ymer_node
    |> Application.get_env(__MODULE__, [])
    |> Keyword.fetch!(:port)
  end

  @doc """
  The bind address (`config :ymer_node, YmerNode.Mcp, :ip`). Defaults to
  loopback; a node run in a container is widened there, where a published port
  needs it — see the module doc for why that does not widen the node's reach.

  Deliberately not read from the environment here, and the configuration that
  runs the node must not fill it from one either. Changing it is a security
  decision, so it costs a committed configuration and a review, never a variable
  set when the node starts. `YmerNode.McpTest` pins this default.
  """
  def ip do
    :ymer_node
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:ip, {127, 0, 0, 1})
  end
end
