defmodule YmerNode.Mcp.Endpoint do
  @moduledoc """
  The HTTP entry point: routes `/mcp` to the mount module the listener was
  started with, and every other path to the carrying application's pages plug
  (`YmerNode.Mcp.pages/0`), or answers it 404 where none is named.

  It exists because the two halves it joins each decline the job. Bandit serves
  one plug and does no path matching, and a mount module answers MCP at its own
  root: it is built to be `forward`ed to, so a mount module wired straight into
  Bandit would answer MCP on `/` and leave the `/mcp` in this node's documented
  address unanswered. Neither is wrong. This module owns that address, and is
  the whole of what a Phoenix app would get from its endpoint and router.

  The mount module and the pages plug arrive as this plug's option instead of
  being named in `forward` lines, because either may be the carrying
  application's, named in configuration that `ymer_node`'s own compile never
  sees: `forward … to:` initializes its target while the module naming it
  compiles. The listener is started with both checked, by `YmerNode.Mcp.mount/0`
  and `YmerNode.Mcp.pages/0`; `init/1` calls each one's `init([])` once, as
  Bandit starts, so a pages plug that raises there stops the node before
  anything listens; and every request carries the options they returned
  unchanged — the mount module's, the ones its `use Wymcp.Router` validated.

  `/mcp` and every path under it are the mount module's, matched as `Plug.Router`
  matches them: on the decoded first segment, case-sensitively, so `/%6Dcp` is
  `/mcp` and `/MCP` is not. Every other path, `/mcpx` included, is handed to
  the pages plug as the request arrived: path and `script_name` unchanged, no
  assign added, so a Phoenix endpoint there routes from the root as it would on
  a listener of its own, and answers its own 404s. The node keeps no assign of
  its own on any path; wymcp hands every assign it does not own to each tool's
  context.

  Where no pages plug is named, every other path answers 404 plainly: a client
  that asked for something other than `/mcp` is misconfigured, and saying so
  beats answering MCP to it.
  """
  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init({mount, pages}) when is_atom(mount) and is_atom(pages),
    do: {{mount, mount.init([])}, init_pages(pages)}

  @impl Plug
  def call(%Plug.Conn{path_info: [segment | glob]} = conn, {{mount, mount_options}, pages}) do
    if URI.decode(segment) == "mcp",
      do: Plug.forward(conn, glob, mount, mount_options),
      else: serve_pages(conn, pages)
  end

  def call(conn, {_mount, pages}), do: serve_pages(conn, pages)

  defp init_pages(nil), do: nil
  defp init_pages(pages), do: {pages, pages.init([])}

  defp serve_pages(conn, nil), do: send_resp(conn, 404, "Not found")
  defp serve_pages(conn, {pages, pages_options}), do: pages.call(conn, pages_options)
end
