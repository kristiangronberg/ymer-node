defmodule YmerNode.Mcp.EndpointTest do
  @moduledoc """
  Drives the endpoint as Bandit does, through `init/1` once and `call/2` per
  request, with no listener: `Plug.Test` builds each request. The mount modules
  are the node's own, `YmerNode.Mcp`, and `YmerNode.CarryingMount` from
  `test/support`, standing in for a carrying application's.
  `YmerNode.CarryingPages` and `YmerNode.FailingPages`, beside them, stand in
  for its pages plug; the first sends the test process each conn it is handed.
  """
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias YmerNode.Mcp.Endpoint

  defp post_mcp(endpoint_options, body) do
    :post
    |> conn("/mcp", JSON.encode!(body))
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json, text/event-stream")
    |> Wymcp.Testing.put_mirrored_headers(body)
    |> Endpoint.call(endpoint_options)
  end

  describe "call/2" do
    test "serves the node's own tools on /mcp when started with YmerNode.Mcp" do
      options = Endpoint.init({YmerNode.Mcp, nil})
      conn = post_mcp(options, Wymcp.Testing.build_request("tools/list"))

      assert conn.status == 200
      names = for tool <- JSON.decode!(conn.resp_body)["result"]["tools"], do: tool["name"]

      assert names == [
               "messages",
               "notebook",
               "references",
               "schedules",
               "script_author",
               "scripts",
               "help"
             ]
    end

    @tag doc: """
         Guards the hand-off wymcp fails open on: a mount module handed options
         its own `init([])` did not build is served with an empty tool list, not
         refused. A failure listing no tools means the endpoint stopped passing
         the options `init/1` built.
         """
    test "serves the mount module it was started with on /mcp" do
      options = Endpoint.init({YmerNode.CarryingMount, nil})
      conn = post_mcp(options, Wymcp.Testing.build_request("tools/list"))

      assert conn.status == 200
      names = for tool <- JSON.decode!(conn.resp_body)["result"]["tools"], do: tool["name"]
      assert "ui" in names
      assert "notebook" in names
    end

    test "runs the carrying application's own tool" do
      options = Endpoint.init({YmerNode.CarryingMount, nil})
      body = Wymcp.Testing.build_action_request("ui", "show")

      assert options |> post_mcp(body) |> Wymcp.Testing.text_response() =~ "ok"
    end

    @tag doc: """
         Guards a leak found at review: wymcp hands every assign it does not own
         to each tool's context, so an assign the endpoint keeps on `/mcp` reaches
         every tool. A failure listing a key means the endpoint added one.
         """
    test "hands a tool no assign of its own" do
      options = Endpoint.init({YmerNode.CarryingMount, nil})
      body = Wymcp.Testing.build_action_request("ui", "assigns")

      text = options |> post_mcp(body) |> Wymcp.Testing.text_response()
      assert JSON.decode!(text) == %{"keys" => []}
    end

    test "answers 404 off /mcp" do
      options = Endpoint.init({YmerNode.Mcp, nil})

      for path <- ["/", "/mcpx", "/MCP"] do
        conn = :get |> conn(path) |> Endpoint.call(options)

        assert conn.status == 404
      end
    end

    test "hands every path but /mcp to the pages plug as it arrived" do
      options = Endpoint.init({YmerNode.Mcp, YmerNode.CarryingPages})

      for path <- ["/", "/mcpx", "/MCP", "/live/websocket"] do
        request = conn(:get, path)

        assert Endpoint.call(request, options).resp_body == "pages"
        assert_received {:pages_conn, ^request}
      end
    end

    test "keeps /mcp and every path under it from the pages plug" do
      options = Endpoint.init({YmerNode.Mcp, YmerNode.CarryingPages})

      for path <- ["/mcp", "/mcp/", "/mcp/x", "/%6Dcp"] do
        conn = :get |> conn(path) |> Endpoint.call(options)

        assert conn.status == 405
        refute_received {:pages_conn, _}
      end
    end

    test "serves the mount module on /mcp with a pages plug named" do
      options = Endpoint.init({YmerNode.CarryingMount, YmerNode.CarryingPages})
      conn = post_mcp(options, Wymcp.Testing.build_request("tools/list"))

      assert conn.status == 200
      names = for tool <- JSON.decode!(conn.resp_body)["result"]["tools"], do: tool["name"]
      assert "ui" in names
      refute_received {:pages_conn, _}
    end
  end

  describe "init/1" do
    test "builds the pages plug's options with its own init/1" do
      assert {_mount, {YmerNode.CarryingPages, :carrying_pages}} =
               Endpoint.init({YmerNode.Mcp, YmerNode.CarryingPages})

      assert_received {:pages_init, []}
    end

    test "raises what the pages plug's init/1 raises" do
      assert_raise RuntimeError, "carrying pages refused to start", fn ->
        Endpoint.init({YmerNode.Mcp, YmerNode.FailingPages})
      end
    end

    @tag doc: """
         A failure means a configuration that names this module as its own pages
         plug would start the node instead of stopping it.
         """
    test "refuses this module as its own pages plug" do
      assert_raise FunctionClauseError, fn ->
        Endpoint.init({YmerNode.Mcp, YmerNode.Mcp.Endpoint})
      end
    end
  end
end
