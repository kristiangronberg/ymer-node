defmodule YmerNode.ApplicationMountTest do
  @moduledoc """
  The listener's half of the `mount:` key, apart from `YmerNode.ApplicationTest`
  because it cannot run beside it: each case sets or clears
  `config :ymer_node, YmerNode.Mcp, :mount` in the application environment, so
  this module is `async: false` and puts the environment back after every case.
  It reads the child list, as `YmerNode.ApplicationTest` does, and starts
  nothing.
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

  defp listener_plug do
    {Bandit, options} = Enum.find(YmerNode.Application.children(), &match?({Bandit, _}, &1))
    Keyword.fetch!(options, :plug)
  end

  describe "children/0" do
    test "starts the listener with YmerNode.Mcp when no mount module is named" do
      environment = Application.get_env(:ymer_node, YmerNode.Mcp, [])
      Application.put_env(:ymer_node, YmerNode.Mcp, Keyword.delete(environment, :mount))

      assert listener_plug() == {YmerNode.Mcp.Endpoint, YmerNode.Mcp}
    end

    test "starts the listener with the mount module the configuration names" do
      name_mount(YmerNode.CarryingMount)

      assert listener_plug() == {YmerNode.Mcp.Endpoint, YmerNode.CarryingMount}
    end

    @tag doc: """
         A failure means a wrong mount module no longer stops the node at
         start: the application would build its tree and serve a surface
         nobody chose.
         """
    test "raises before the tree is built when the named mount module is wrong" do
      name_mount(YmerNode.PartialMount)

      assert_raise ArgumentError, ~r/:mount names YmerNode.PartialMount/, fn ->
        YmerNode.Application.children()
      end
    end
  end
end
