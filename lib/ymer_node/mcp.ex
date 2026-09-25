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
  not reachable from the network — but *where* that pin lives differs between the
  two ways the node runs, and conflating them is how the guarantee gets lost.

  Run directly on a machine, the node pins it itself: `ip/0` defaults to loopback,
  so it binds `127.0.0.1` and nothing off-box can reach it.

  Run in the node's own container, it cannot: a process bound to loopback inside a
  container is unreachable through a published port, so *that* image binds all
  interfaces *within its own network namespace* — and the pin moves to the **host
  publish**. Only this repo's image does: the release carries no wide bind of its
  own, so the same release in someone else's image binds loopback and its
  published port reaches nobody.
  `docker-compose.yml` hardcodes the `127.0.0.1:` prefix for exactly this reason,
  and that prefix is the whole guarantee: a hand-rolled `docker run -p 8012:8012`
  **without** it publishes on every interface and exposes an unauthenticated SQL
  surface to the LAN. Use the compose file, or carry the prefix yourself.

  What widens the bind is the **bind marker**: an empty file the node's own image
  writes at a fixed path outside the release directory, which `config/runtime.exs`
  checks at boot. Its presence is the whole widening, only a build produces it, and
  copying the release out of the image cannot carry it — so a release started bare
  on a host binds loopback and exposes nothing to that host's networks. Widening
  still costs a committed artifact, and the environment cannot forge one: there is
  no variable that turns it on.

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
          "search, a registry of pointers at where knowledge lives, and the " <>
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
  The bind address. Defaults to loopback; the node's own image widens it to all
  interfaces through the bind marker `config/runtime.exs` reads at boot, where a
  container's published port needs it — see the module doc for why that does not
  widen the node's reach.

  Deliberately not readable from the environment. Changing it is a security
  decision, so it costs a committed artifact and a review, never a variable set
  at `docker run` time. `YmerNode.McpTest` pins this default and pins that
  `config/prod.exs` sets no bind address; `YmerNode.ReleaseConfigTest` evaluates
  `config/runtime.exs` as a release boot would and pins that the widening stays
  behind the marker.
  """
  def ip do
    :ymer_node
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:ip, {127, 0, 0, 1})
  end
end
