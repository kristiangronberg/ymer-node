defmodule YmerNode.Mcp.Endpoint do
  @moduledoc """
  The HTTP entry point: routes `/mcp` to the mount module the listener was
  started with, and answers 404 to everything else.

  It exists because the two halves it joins each decline the job. Bandit serves
  one plug and does no path matching, and a mount module reads no path at all:
  it is built to be `forward`ed to, so a mount module wired straight into Bandit
  would answer MCP on *every* path, `/` included. Neither is wrong; they just
  leave the `/mcp` in this node's documented address unowned. This module owns
  it, and is the whole of what a Phoenix app would get from its endpoint and
  router.

  The mount module arrives as this plug's option instead of being named in a
  `forward` line, because it may be the carrying application's, named in
  configuration that `ymer_node`'s own compile never sees: `forward … to:`
  initializes its target while this module compiles. The listener is started
  with the module `YmerNode.Mcp.mount/0` checked, `init/1` builds that module's
  options once, as Bandit starts, and every request carries those options to it
  unchanged — the ones its `use Wymcp.Router` validated.

  The catch-all 404 is deliberate rather than incidental: the node serves exactly
  one path, so anything else is a client misconfiguration, and saying so plainly
  beats answering MCP to a caller who asked for something else.
  """
  use Plug.Router, copy_opts_to_assign: :mcp_mount

  plug(:match)
  plug(:dispatch)

  @impl Plug
  def init(mount) when is_atom(mount), do: {mount, mount.init([])}

  # The assign is dropped before the forward: wymcp hands every assign it does
  # not own to each tool's context, so leaving it would give every tool the
  # mount module's whole router options.
  match "/mcp/*glob" do
    {{mount, mount_options}, assigns} = Map.pop!(conn.assigns, :mcp_mount)
    Plug.forward(%{conn | assigns: assigns}, glob, mount, mount_options)
  end

  match _ do
    send_resp(conn, 404, "Not found")
  end
end
