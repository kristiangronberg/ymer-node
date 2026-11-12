defmodule YmerNode.Mcp do
  @moduledoc """
  The node's mount module — its entire external surface.

  The tool list is declared here and nowhere else, and it is read at this module's
  compile: a tool whose action schemas are malformed fails the build rather than
  the first request. That is also why the list is written out literally instead of
  read from configuration — naming the modules here is what records the
  compile-time dependency that keeps the check from going stale.

  ## A carrying application's tools

  The [*carrying application*](docs/glossary.md#carrying-application) can serve
  tools of its own on the same `/mcp`. It writes a mount module of its own with
  `use Wymcp.Router`, listing `tools/0` and then its own tools, with
  `YmerNode.Mcp.McpServer.instructions/0` as its instructions and
  `server_info/0` as its serverInfo, and names that module in
  `config :ymer_node, YmerNode.Mcp, :mount`. wymcp validates every tool's
  schemas, and refuses a tool name used twice, while that module compiles, in
  the carrying application's build. The listener, its port and its bind address
  stay this module's.

  The named module must serve every tool in `tools/0`: the instructions describe
  them all, so a node carried anywhere serves the same surface. `mount/0` checks
  that as the listener starts. A mount module that lists the tools literally
  instead of calling `tools/0` is refused there once a release of `ymer_node`
  adds a tool.

  The listener starts with `ymer_node`, and `ymer_node` has started before the
  carrying application that depends on it starts, so `/mcp` answers before the
  carrying application's own processes exist. A tool of its own must answer a
  call made before its application is up; `ymer_node` does not hold the listener
  back for it.

  ## A carrying application's pages

  The carrying application can serve pages of its own on the node's port too. It
  names a plug, its pages plug (`pages/0`), in
  `config :ymer_node, YmerNode.Mcp, :pages`; `YmerNode.Mcp.Endpoint` says which
  paths reach it, and what they answer where none is named. A Phoenix endpoint
  started with `server: false` is such a plug, and its LiveView socket is a path
  like any other. A mount module belongs in `:mount`: `pages/0` does not refuse
  one named in `:pages`, where it would answer `/` as it answers `/mcp` and turn
  other paths away.

  The pages plug guards its own paths, since `/mcp`'s guards do not reach them.
  A page that carries notebook rows should check each request's Host against the
  loopback address (`127.0.0.1`, `[::1]`) and `localhost`, with the port the node
  is reached on, and keep its socket's origin check. That Host check does not
  follow `ip/0`: a container's widened bind (`0.0.0.0`) is never a Host to
  accept, and the port a host publishes may differ from `port/0`. The loopback
  pin and the host publish's `127.0.0.1:` prefix (§ Loopback is the security
  model) protect the pages plug's paths exactly as they do `/mcp`; a Host or
  origin check guards only against other web pages in a browser on this
  machine, never against a client that can reach the port. The listener starts
  before the carrying application, as it does for that application's tools, and
  stops after it, so the pages plug must answer a request made before its
  application has started or after it has stopped; an unstarted Phoenix
  endpoint answers 500.

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
  The `:mount` key, read by `mount/0`, stands on the same footing: the mount
  module it names sets `/mcp`'s own `:auth` and `:origin`, so naming one decides
  how `/mcp` is guarded, and it too is a committed configuration that the
  environment must never fill.
  The `:pages` key, read by `pages/0`, stands there as well: the pages plug it
  names decides how every path but `/mcp` is guarded, so it is a committed
  configuration that the environment must never fill.

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
  # so an alias written below the `use` line would not be in scope for them. The
  # two attributes sit there for the same reason, and `tools/0` and
  # `server_info/0` read them back, since a function of this module cannot be
  # called while the module is still compiling.
  alias YmerNode.Mcp.McpServer

  @tools [
    YmerNode.Mcp.Tools.Messages,
    YmerNode.Mcp.Tools.Notebook,
    YmerNode.Mcp.Tools.References,
    YmerNode.Mcp.Tools.Schedules,
    YmerNode.Mcp.Tools.ScriptAuthor,
    YmerNode.Mcp.Tools.Scripts
  ]

  @server_info %{
    title: "Ymer Node",
    description:
      "Local capability for LLM workers: a private SQL notebook with vector " <>
        "search, a registry of pointers at where knowledge lives with a cache of " <>
        "what they say, and the " <>
        "scripts this node has accepted. All of it stays on this machine. " <>
        "The local half of Ymer."
  }

  use Wymcp.Router,
    tools: @tools,
    instructions: McpServer.instructions(),
    server_info: @server_info

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

  @doc """
  The mount module `/mcp` serves (`config :ymer_node, YmerNode.Mcp, :mount`),
  this module where the key is unset. Read once, as the listener starts.

  Raises unless the named module exists, is a mount module, and serves every
  tool in `tools/0`, so a wrong name stops the node at start instead of serving
  a surface nobody chose. There is no fallback to this module: it would drop the
  carrying application's tools without a word.

  Like `ip/0`, deliberately not read from the environment: naming the module
  decides how `/mcp` is guarded. The module doc's § Loopback is the security
  model says why that costs a committed configuration.
  """
  def mount do
    :ymer_node
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:mount, __MODULE__)
    |> check_mount!()
  end

  @doc """
  The pages plug: the carrying application's plug that `YmerNode.Mcp.Endpoint`
  hands every request whose path is not `/mcp` or under it, named in
  `config :ymer_node, YmerNode.Mcp, :pages`; none where the key is unset or
  `nil`. Read once, as the listener starts, and `nil` where there is none.

  Raises unless the named module exists and exports both `init/1` and `call/2`,
  so a wrong name stops the node at start instead of answering 404 in its
  place. `nil` is the one value it accepts that `mount/0` refuses: a later
  config file cannot remove a key it inherits, only set it, so `nil` is how one
  turns an inherited pages plug off.

  Like `mount/0`, deliberately not read from the environment: the pages plug
  decides how every path but `/mcp` is guarded. The module doc's § Loopback is
  the security model says why that costs a committed configuration.
  """
  def pages do
    :ymer_node
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:pages)
    |> check_pages!()
  end

  # ─── Public API ─────────────────────────────────────────────────────

  @doc """
  The node's tools, in the order this module serves them — the list a carrying
  application's mount module starts its `:tools` from. Calling it there records
  a compile-time dependency on this module, and through it on each tool, so an
  edit to a tool recompiles that mount module too.

  It exists to compose the mount module the node's own listener serves. Any
  listener that serves these tools is bound by the loopback model in this
  module's doc: the tools carry no authentication of their own.

  ## Examples

      iex> YmerNode.Mcp.Tools.Notebook in YmerNode.Mcp.tools()
      true

  """
  def tools, do: @tools

  @doc """
  The serverInfo `title` and `description` this module serves, for a carrying
  application's mount module to pass unchanged. serverInfo's `name` and
  `version` are not in it: wymcp reads those from `config :wymcp`, which the
  carrying application sets for its own release.

  ## Examples

      iex> YmerNode.Mcp.server_info().title
      "Ymer Node"

  """
  def server_info, do: @server_info

  # ─── Private ────────────────────────────────────────────────────────

  defp check_mount!(mount) when is_atom(mount) do
    if Code.ensure_loaded?(mount) do
      mount |> served_tools() |> check_served!(mount)
    else
      refuse_mount!(mount, "names no module that exists")
    end
  end

  defp check_mount!(mount), do: refuse_mount!(mount, "is not a module name")

  defp check_served!(:not_a_mount, mount),
    do: refuse_mount!(mount, "is not a mount module: it does not `use Wymcp.Router`")

  defp check_served!(served, mount) do
    case @tools -- served do
      [] -> mount
      missing -> refuse_mount!(mount, "does not serve #{inspect(missing)}")
    end
  end

  # `Wymcp.Testing.registrations/1` is wymcp's one public read of what a mount
  # module serves. The options a mount module's `init/1` returns are the
  # router's own, and wymcp may change their keys in any release, so reading
  # them here could break silently on a wymcp upgrade.
  defp served_tools(mount) do
    mount |> Wymcp.Testing.registrations() |> Enum.map(& &1.module)
  rescue
    Wymcp.ConfigurationError -> :not_a_mount
  end

  defp refuse_mount!(mount, problem) do
    raise ArgumentError,
          "config :ymer_node, YmerNode.Mcp, :mount names #{inspect(mount)}, which #{problem}"
  end

  # Exports alone, as Plug itself reads a module plug: it calls `init/1` and
  # `call/2` and never reads `@behaviour Plug`, so requiring the attribute would
  # refuse a working plug.
  defp check_pages!(nil), do: nil

  defp check_pages!(pages) when is_atom(pages) do
    cond do
      not Code.ensure_loaded?(pages) ->
        refuse_pages!(pages, "names no module that exists")

      function_exported?(pages, :init, 1) and function_exported?(pages, :call, 2) ->
        pages

      true ->
        refuse_pages!(pages, "is not a plug: it does not export both `init/1` and `call/2`")
    end
  end

  defp check_pages!(pages), do: refuse_pages!(pages, "is not a module name")

  defp refuse_pages!(pages, problem) do
    raise ArgumentError,
          "config :ymer_node, YmerNode.Mcp, :pages names #{inspect(pages)}, which #{problem}"
  end
end
