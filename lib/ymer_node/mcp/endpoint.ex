defmodule YmerNode.Mcp.Endpoint do
  @moduledoc """
  The HTTP entry point: routes paths to `YmerNode.Mcp`, and answers 404 to
  everything else.

  It exists because the two halves it joins each decline the job. Bandit serves
  one plug and does no path matching, and `YmerNode.Mcp` — a `Wymcp.Router` mount —
  reads no path at all: it is built to be `forward`ed to, so a mount wired straight
  into Bandit would answer MCP on *every* path, `/` included. Neither is wrong;
  they just leave the `/mcp` in this node's documented address unowned. This module
  owns it, and is the whole of what a Phoenix app would get from its endpoint and
  router.

  The catch-all 404 is deliberate rather than incidental: the node serves exactly
  one path, so anything else is a client misconfiguration, and saying so plainly
  beats handing an MCP session to a caller who asked for something else.
  """
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  forward("/mcp", to: YmerNode.Mcp)

  match _ do
    send_resp(conn, 404, "Not found")
  end
end
