defmodule YmerNode.Mcp.MountTest do
  @moduledoc """
  The cases on `YmerNode.Mcp.mount/0`, apart from `YmerNode.McpTest` because
  they cannot run beside it: each sets or clears
  `config :ymer_node, YmerNode.Mcp, :mount` in the application environment,
  which every reader of `YmerNode.Mcp`'s keys shares, so this module is
  `async: false` and puts the environment back after every case. Beside the
  node's own module, the mount modules it names are `YmerNode.CarryingMount`
  and `YmerNode.PartialMount`, compiled from `test/support`.
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

  defp name_mount(mount) do
    environment = Application.get_env(:ymer_node, YmerNode.Mcp, [])
    Application.put_env(:ymer_node, YmerNode.Mcp, Keyword.put(environment, :mount, mount))
  end

  describe "mount/0" do
    test "is YmerNode.Mcp when no mount module is named" do
      environment = Application.get_env(:ymer_node, YmerNode.Mcp, [])
      Application.put_env(:ymer_node, YmerNode.Mcp, Keyword.delete(environment, :mount))

      assert YmerNode.Mcp.mount() == YmerNode.Mcp
    end

    test "is YmerNode.Mcp when YmerNode.Mcp is named" do
      name_mount(YmerNode.Mcp)

      assert YmerNode.Mcp.mount() == YmerNode.Mcp
    end

    test "is the named mount module when it serves every tool of the node's" do
      name_mount(YmerNode.CarryingMount)

      assert YmerNode.Mcp.mount() == YmerNode.CarryingMount
    end

    test "refuses a name that is no module" do
      name_mount(YmerNode.NoSuchMount)

      assert_raise ArgumentError,
                   "config :ymer_node, YmerNode.Mcp, :mount names YmerNode.NoSuchMount, " <>
                     "which names no module that exists",
                   &YmerNode.Mcp.mount/0
    end

    test "refuses a value that is not a module name" do
      name_mount("YmerDesktop.Mcp")

      assert_raise ArgumentError,
                   ~s(config :ymer_node, YmerNode.Mcp, :mount names "YmerDesktop.Mcp", ) <>
                     "which is not a module name",
                   &YmerNode.Mcp.mount/0
    end

    test "refuses a module that is not a mount module" do
      name_mount(YmerNode.CarryingMount.Ui)

      assert_raise ArgumentError,
                   "config :ymer_node, YmerNode.Mcp, :mount names YmerNode.CarryingMount.Ui, " <>
                     "which is not a mount module: it does not `use Wymcp.Router`",
                   &YmerNode.Mcp.mount/0
    end

    @tag doc: """
         A failure means a mount module that leaves out one of the node's tools
         would start serving: the instructions would then describe a tool its
         clients cannot call. The refusal names the missing tool modules, so a
         carrying application that listed the tools literally finds the one a
         release of `ymer_node` added.
         """
    test "refuses a mount module that leaves out a tool of the node's" do
      name_mount(YmerNode.PartialMount)

      message = assert_raise(ArgumentError, &YmerNode.Mcp.mount/0).message

      assert message =~
               "config :ymer_node, YmerNode.Mcp, :mount names YmerNode.PartialMount, " <>
                 "which does not serve ["

      assert message =~ "YmerNode.Mcp.Tools.Messages"
      refute message =~ "YmerNode.Mcp.Tools.Notebook"
    end
  end
end
