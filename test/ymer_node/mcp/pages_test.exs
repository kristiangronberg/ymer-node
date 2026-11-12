defmodule YmerNode.Mcp.PagesTest do
  @moduledoc """
  The cases on `YmerNode.Mcp.pages/0`, apart from `YmerNode.McpTest` because
  they cannot run beside it: each sets or clears
  `config :ymer_node, YmerNode.Mcp, :pages` in the application environment,
  which every reader of `YmerNode.Mcp`'s keys shares, so this module is
  `async: false` and puts the environment back after every case. The pages plug
  it names is `YmerNode.CarryingPages`, compiled from `test/support`.
  """
  use ExUnit.Case, async: false

  setup do
    saved = Application.get_env(:ymer_node, YmerNode.Mcp)

    on_exit(fn ->
      if saved,
        do: Application.put_env(:ymer_node, YmerNode.Mcp, saved),
        else: Application.delete_env(:ymer_node, YmerNode.Mcp)
    end)
  end

  defp name_pages(pages) do
    environment = Application.get_env(:ymer_node, YmerNode.Mcp, [])
    Application.put_env(:ymer_node, YmerNode.Mcp, Keyword.put(environment, :pages, pages))
  end

  describe "pages/0" do
    test "is nil when no pages plug is named" do
      environment = Application.get_env(:ymer_node, YmerNode.Mcp, [])
      Application.put_env(:ymer_node, YmerNode.Mcp, Keyword.delete(environment, :pages))

      assert YmerNode.Mcp.pages() == nil
    end

    @tag doc: """
         A failure means `nil` is refused, as `mount/0` refuses it.
         """
    test "is nil when the key is nil" do
      name_pages(nil)

      assert YmerNode.Mcp.pages() == nil
    end

    test "is the named plug" do
      name_pages(YmerNode.CarryingPages)

      assert YmerNode.Mcp.pages() == YmerNode.CarryingPages
    end

    test "is a mount module named in its place, unrefused" do
      name_pages(YmerNode.Mcp)

      assert YmerNode.Mcp.pages() == YmerNode.Mcp
    end

    test "refuses a name that is no module" do
      name_pages(YmerNode.NoSuchPages)

      assert_raise ArgumentError,
                   "config :ymer_node, YmerNode.Mcp, :pages names YmerNode.NoSuchPages, " <>
                     "which names no module that exists",
                   &YmerNode.Mcp.pages/0
    end

    test "refuses a value that is not a module name" do
      name_pages("YmerDesktopWeb.Endpoint")

      assert_raise ArgumentError,
                   ~s(config :ymer_node, YmerNode.Mcp, :pages names "YmerDesktopWeb.Endpoint", ) <>
                     "which is not a module name",
                   &YmerNode.Mcp.pages/0
    end

    test "refuses a module that is not a plug" do
      name_pages(YmerNode.Mcp.McpServer)

      assert_raise ArgumentError,
                   "config :ymer_node, YmerNode.Mcp, :pages names YmerNode.Mcp.McpServer, " <>
                     "which is not a plug: it does not export both `init/1` and `call/2`",
                   &YmerNode.Mcp.pages/0
    end

    test "refuses a module that exports init/1 alone" do
      name_pages(YmerNode.InitOnlyPages)

      assert_raise ArgumentError,
                   "config :ymer_node, YmerNode.Mcp, :pages names YmerNode.InitOnlyPages, " <>
                     "which is not a plug: it does not export both `init/1` and `call/2`",
                   &YmerNode.Mcp.pages/0
    end

    test "refuses a module that exports call/2 alone" do
      name_pages(YmerNode.CallOnlyPages)

      assert_raise ArgumentError,
                   "config :ymer_node, YmerNode.Mcp, :pages names YmerNode.CallOnlyPages, " <>
                     "which is not a plug: it does not export both `init/1` and `call/2`",
                   &YmerNode.Mcp.pages/0
    end
  end
end
