defmodule YmerNode.Scripts.BrowserServiceTest do
  @moduledoc """
  The browser service is never started here: every call meets `Req.Test`'s
  stub under the `YmerNode.Script.Context` name, which `config/test.exs` puts
  in the node's request options. The stubbed answers are the service's own, as
  it sends them — a success, one failure per kind — so a change to the wire on
  either side shows up as a failure here or in the service's own tests.

  Not async: the `url/0` and token cases put keys in the application
  environment, which is VM-global. The token cases name a file under their
  own `tmp_dir`, so none reads or writes the one in the home directory.
  """
  use ExUnit.Case, async: false

  alias YmerNode.Script.Context
  alias YmerNode.Scripts.BrowserService
  alias YmerNode.Scripts.BrowserService.Error

  @png <<0x89, 0x50, 0x4E, 0x47>>

  defp deadline(milliseconds \\ 10_000), do: System.monotonic_time(:millisecond) + milliseconds

  defp failure(kind, fields \\ %{}) do
    %{
      "ok" => false,
      "error" =>
        Map.merge(
          %{
            "kind" => kind,
            "name" => "Error",
            "message" => "it failed",
            "call_log" => [],
            "url" => "about:blank",
            "title" => "",
            "screenshot" => nil
          },
          fields
        )
    }
  end

  # Answers the Authorization headers each request carried, in order.
  defp authorizations(fun) do
    test = self()

    Req.Test.stub(Context, fn conn ->
      send(test, {:authorization, Plug.Conn.get_req_header(conn, "authorization")})
      Req.Test.transport_error(conn, :econnrefused)
    end)

    fun.()
    collect_authorizations([])
  end

  defp collect_authorizations(seen) do
    receive do
      {:authorization, header} -> collect_authorizations([header | seen])
    after
      0 -> Enum.reverse(seen)
    end
  end

  describe "call/3" do
    test "posts the code and its options, and answers the value with the page it ended on" do
      Req.Test.stub(Context, fn conn ->
        assert {conn.method, conn.request_path} == {"POST", "/call"}
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = JSON.decode!(raw)

        assert body["code"] == "async (page) => 1"
        assert body["args"] == %{"n" => 2}
        assert body["storage"] == "crosskey"
        assert body["save_storage"] == true
        assert body["browser_context"] == %{"locale" => "fi-FI"}
        assert body["screenshot"] == false
        assert body["bound_ms"] in 7_000..8_000

        Req.Test.json(conn, %{
          "ok" => true,
          "value" => "hi",
          "url" => "https://ymer.ax/",
          "title" => "Ymer",
          "duration_ms" => 44
        })
      end)

      assert {:ok, %{value: "hi", url: "https://ymer.ax/", title: "Ymer", duration_ms: 44}} =
               BrowserService.call(deadline(), "async (page) => 1",
                 args: %{n: 2},
                 storage: "crosskey",
                 save_storage: true,
                 browser_context: %{locale: "fi-FI"},
                 screenshot: false
               )
    end

    test "sends the defaults when the script passes no options" do
      Req.Test.stub(Context, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)

        assert %{
                 "args" => %{},
                 "storage" => nil,
                 "save_storage" => false,
                 "browser_context" => %{},
                 "screenshot" => true
               } = JSON.decode!(raw)

        Req.Test.json(conn, %{
          "ok" => true,
          "value" => nil,
          "url" => "about:blank",
          "title" => "",
          "duration_ms" => 1
        })
      end)

      assert {:ok, %{value: nil}} = BrowserService.call(deadline(), "async () => {}", [])
    end

    test "answers a thrown failure with Playwright's message, call log and the screenshot's bytes" do
      Req.Test.stub(Context, fn conn ->
        Req.Test.json(
          conn,
          failure("thrown", %{
            "message" => "expect(locator).toHaveText(expected) failed",
            "call_log" => ["- waiting for getByRole('heading')"],
            "screenshot" => Base.encode64(@png)
          })
        )
      end)

      assert {:error, %Error{} = error} = BrowserService.call(deadline(), "async () => 1", [])
      assert error.kind == :thrown
      assert error.call_log == ["- waiting for getByRole('heading')"]
      assert error.screenshot == @png

      assert Exception.message(error) ==
               "browser call failed (thrown): expect(locator).toHaveText(expected) failed"
    end

    test "answers each of the service's kinds as its atom" do
      for kind <- ~w(code thrown storage value timeout) do
        Req.Test.stub(Context, fn conn -> Req.Test.json(conn, failure(kind)) end)

        assert {:error, %Error{kind: atom}} = BrowserService.call(deadline(), "async () => 1", [])
        assert Atom.to_string(atom) == kind
      end
    end

    test "sends nothing and answers timeout when the deadline leaves no time" do
      Req.Test.stub(Context, fn _conn -> flunk("a call with no time left was sent") end)

      assert {:error, %Error{kind: :timeout, message: message}} =
               BrowserService.call(deadline(500), "async () => 1", [])

      assert message =~ "no time for a browser call"
    end

    test "answers unreachable, naming what to run, when nothing answers" do
      Req.Test.stub(Context, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, %Error{kind: :unreachable} = error} =
               BrowserService.call(deadline(), "async () => 1", [])

      assert error.message =~ "nothing answers at http://127.0.0.1:8013"
      assert error.message =~ "run `npm start` in browser-service/"
      assert error.message =~ "BROWSER_SERVICE_URL"
    end

    test "answers timeout when the service does not answer before the deadline" do
      Req.Test.stub(Context, fn conn -> Req.Test.transport_error(conn, :timeout) end)

      assert {:error, %Error{kind: :timeout}} =
               BrowserService.call(deadline(), "async () => 1", [])
    end

    test "answers protocol for an answer that is not the contract" do
      for answer <- [
            fn conn -> Plug.Conn.send_resp(conn, 404, "not here") end,
            fn conn -> Req.Test.json(conn, failure("nonsense")) end,
            fn conn -> Req.Test.json(conn, %{"ok" => true}) end,
            fn conn ->
              Req.Test.json(conn, failure("thrown", %{"screenshot" => "not base64!"}))
            end
          ] do
        Req.Test.stub(Context, answer)

        assert {:error, %Error{kind: :protocol}} =
                 BrowserService.call(deadline(), "async () => 1", [])
      end
    end

    test "answers protocol with the service's own text when it refuses the request" do
      Req.Test.stub(Context, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(400, JSON.encode!(%{"error" => "args must be an object"}))
      end)

      assert {:error, %Error{kind: :protocol, message: message}} =
               BrowserService.call(deadline(), "async () => 1", [])

      assert message =~ "args must be an object"
      refute message =~ "another program"
    end

    test "refuses save_storage without a storage name, sending nothing" do
      Req.Test.stub(Context, fn _conn -> flunk("a call with no name to save under was sent") end)

      assert_raise ArgumentError, ~r/needs storage:/, fn ->
        BrowserService.call(deadline(), "async () => 1", save_storage: true)
      end
    end

    test "refuses an option it does not know" do
      assert_raise ArgumentError, fn ->
        BrowserService.call(deadline(), "async () => 1", timeout: 5_000)
      end
    end
  end

  describe "status/0" do
    test "reports what the service measured, when it answered" do
      Req.Test.stub(Context, fn conn ->
        assert {conn.method, conn.request_path} == {"GET", "/status"}

        Req.Test.json(conn, %{
          "playwright" => "pinned",
          "chromium" => "153.0.8010.12",
          "launch_error" => nil,
          "storage_states" => ["crosskey"],
          "windows" => []
        })
      end)

      assert BrowserService.status() == %{
               url: "http://127.0.0.1:8013",
               answered: true,
               playwright: "pinned",
               chromium: "153.0.8010.12",
               launch_error: nil,
               storage_states: ["crosskey"],
               windows: []
             }
    end

    test "reports that nothing answered, and what to run" do
      Req.Test.stub(Context, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert %{answered: false, message: message} = BrowserService.status()
      assert message =~ "npm start"
    end

    test "reports a service slower than the status wait as one to ask again, not only to start" do
      Req.Test.stub(Context, fn conn -> Req.Test.transport_error(conn, :timeout) end)

      assert %{answered: false, message: message} = BrowserService.status()
      assert message =~ "did not answer within five seconds"
      assert message =~ "ask again in a moment"
      assert message =~ "npm start"
    end

    test "reports a status answer without its lists as not the service's" do
      Req.Test.stub(Context, fn conn -> Req.Test.json(conn, %{"playwright" => "pinned"}) end)

      assert %{answered: true, message: message} = BrowserService.status()
      assert message =~ "not as the browser service"
    end

    test "reports an answer that is not the service's" do
      Req.Test.stub(Context, fn conn -> Plug.Conn.send_resp(conn, 404, "not here") end)

      assert %{answered: true, message: message} = BrowserService.status()
      assert message =~ "not as the browser service"
    end

    test "reports the service's own text when it refuses the request" do
      Req.Test.stub(Context, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          403,
          JSON.encode!(%{
            "error" => "refused: Host 10.0.0.5:8013 is not this machine at port 8013"
          })
        )
      end)

      assert %{answered: true, message: message} = BrowserService.status()
      assert message =~ "Host 10.0.0.5:8013 is not this machine"
      refute message =~ "another program"
    end
  end

  describe "the token" do
    @describetag :tmp_dir

    setup do
      saved = Application.get_env(:ymer_node, BrowserService)

      on_exit(fn ->
        if saved,
          do: Application.put_env(:ymer_node, BrowserService, saved),
          else: Application.delete_env(:ymer_node, BrowserService)
      end)
    end

    test "a configured token is sent on every request, calls and status alike" do
      Application.put_env(:ymer_node, BrowserService, token: "the-token")

      assert authorizations(fn ->
               BrowserService.call(deadline(), "async () => 1", [])
               BrowserService.status()
             end) == [["Bearer the-token"], ["Bearer the-token"]]
    end

    test "with no token configured, the file's is sent, and a missing file is written first, 0600 in a 0700 directory",
         %{tmp_dir: tmp_dir} do
      file = Path.join([tmp_dir, "nested", "browser-service-token"])
      Application.put_env(:ymer_node, BrowserService, token_file: file)

      assert [[first], [second]] =
               authorizations(fn ->
                 BrowserService.call(deadline(), "async () => 1", [])
                 BrowserService.call(deadline(), "async () => 1", [])
               end)

      assert first == "Bearer " <> String.trim(File.read!(file))
      assert second == first
      assert first =~ ~r/\ABearer [A-Za-z0-9_-]{43}\z/
      assert Bitwise.band(File.stat!(file).mode, 0o777) == 0o600
      assert Bitwise.band(File.stat!(Path.dirname(file)).mode, 0o777) == 0o700
      assert File.ls!(Path.dirname(file)) == ["browser-service-token"]
    end

    test "a file another process wrote is read, its line's padding dropped",
         %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "browser-service-token")
      File.write!(file, "  written-elsewhere\n")
      File.chmod!(file, 0o600)
      Application.put_env(:ymer_node, BrowserService, token_file: file)

      assert authorizations(fn -> BrowserService.status() end) == [["Bearer written-elsewhere"]]
      assert File.read!(file) == "  written-elsewhere\n"
    end

    test "with nothing configured — a dev node — BROWSER_SERVICE_TOKEN_FILE names the file",
         %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "moved-token")
      File.write!(file, "moved\n")
      File.chmod!(file, 0o600)
      Application.delete_env(:ymer_node, BrowserService)
      saved = System.get_env("BROWSER_SERVICE_TOKEN_FILE")
      System.put_env("BROWSER_SERVICE_TOKEN_FILE", file)

      on_exit(fn ->
        if saved,
          do: System.put_env("BROWSER_SERVICE_TOKEN_FILE", saved),
          else: System.delete_env("BROWSER_SERVICE_TOKEN_FILE")
      end)

      assert authorizations(fn -> BrowserService.status() end) == [["Bearer moved"]]
    end

    test "a file others can read sends no token, and a warning names the chmod",
         %{tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "browser-service-token")
      File.write!(file, "readable\n")
      File.chmod!(file, 0o644)
      Application.put_env(:ymer_node, BrowserService, token_file: file)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert authorizations(fn -> BrowserService.status() end) == [[]]
        end)

      assert log =~ "(mode 644): run chmod 600 #{file}."
    end

    test "a file it cannot read sends no token, and the service's refusal is the message",
         %{tmp_dir: tmp_dir} do
      Application.put_env(:ymer_node, BrowserService, token_file: tmp_dir)
      refusal = "refused: this request carries no token. The token is the contents of …"

      Req.Test.stub(Context, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == []

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, JSON.encode!(%{"error" => refusal}))
      end)

      assert {:error, %Error{kind: :protocol, message: message}} =
               BrowserService.call(deadline(), "async () => 1", [])

      assert message =~ "refused the request (status 401): " <> refusal
    end

    test "a node configured with no token file — one inside its image — sends none" do
      Application.put_env(:ymer_node, BrowserService, token_file: nil)

      assert authorizations(fn -> BrowserService.status() end) == [[]]
    end

    test "a request a plug answers sends no token when the configuration names none" do
      Application.delete_env(:ymer_node, BrowserService)

      assert authorizations(fn -> BrowserService.status() end) == [[]]
    end
  end

  describe "url/0" do
    setup do
      saved = Application.get_env(:ymer_node, BrowserService)

      on_exit(fn ->
        if saved,
          do: Application.put_env(:ymer_node, BrowserService, saved),
          else: Application.delete_env(:ymer_node, BrowserService)
      end)
    end

    test "answers the host default when nothing configures it" do
      Application.delete_env(:ymer_node, BrowserService)

      assert BrowserService.url() == "http://127.0.0.1:8013"
    end

    test "answers the configured URL, and calls go there" do
      Application.put_env(:ymer_node, BrowserService, url: "http://host.docker.internal:8013")

      Req.Test.stub(Context, fn conn ->
        assert conn.host == "host.docker.internal"
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, %Error{message: message}} =
               BrowserService.call(deadline(), "async () => 1", [])

      assert message =~ "nothing answers at http://host.docker.internal:8013"
    end

    test "drops a trailing slash, so calls reach the service's own paths" do
      Application.put_env(:ymer_node, BrowserService, url: "http://127.0.0.1:8013/")

      Req.Test.stub(Context, fn conn ->
        assert conn.request_path == "/call"
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert BrowserService.url() == "http://127.0.0.1:8013"

      assert {:error, %Error{kind: :unreachable}} =
               BrowserService.call(deadline(), "async () => 1", [])
    end
  end
end
