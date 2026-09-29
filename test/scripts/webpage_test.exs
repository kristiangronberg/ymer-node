defmodule Script.WebpageTest do
  @moduledoc """
  The web fallback the image ships, run against `Req.Test` rather than the
  network, and compiled from its file on disk — the bytes the build plants —
  as `Script.HexTest` compiles `hex.exs`, for the reason that file gives.

  Every page here is a stub's answer: the content type, the validator headers
  and the status are what each case sets, which is the whole of what the
  script decides by.
  """
  use YmerNode.ScriptCase, async: true

  alias YmerNode.Script.Context
  alias YmerNode.Scripts.Compiler

  @path "priv/scripts/webpage.exs"
  @url "https://docs.example.test/guide/start"

  @page """
  <!doctype html>
  <html>
    <head><title>Start</title><style>p { color: red }</style></head>
    <body>
      <nav><a href="/">Home</a></nav>
      <main>
        <h1>Getting started</h1>
        <p>Read the <a href="../reference">reference</a> first, and <strong>then</strong>
          the <em>guide</em>.</p>
        <ul><li>one</li><li>two <code>x</code></li></ul>
        <pre>mix deps.get</pre>
        <blockquote><p>Quoted.</p></blockquote>
        <script>alert(1)</script>
      </main>
      <footer>Copyright</footer>
    </body>
  </html>
  """

  @markdown """
  # Getting started

  Read the [reference](https://docs.example.test/reference) first, and **then** the _guide_.

  - one
  - two `x`

  ```
  mix deps.get
  ```

  > Quoted.
  """

  setup do
    purge_on_exit(Module.concat(["Script", "Webpage"]))
    {:ok, compiled} = @path |> File.read!() |> Compiler.compile()

    %{compiled: compiled, module: compiled.module}
  end

  defp context do
    %Context{
      script: "webpage",
      action: :fetch,
      secrets: [],
      throttles: %{},
      deadline: System.monotonic_time(:millisecond) + 30_000
    }
  end

  defp html(conn, body, headers \\ []) do
    headers
    |> Enum.reduce(conn, fn {name, value}, conn ->
      Plug.Conn.put_resp_header(conn, name, value)
    end)
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.send_resp(200, body)
  end

  defp fetch(module, args), do: module.run(:fetch, Map.put(args, "url", @url), context())

  describe "the shipped file satisfies the contract" do
    test "compiles clean, named webpage", %{compiled: compiled} do
      assert compiled.name == "webpage"
      assert compiled.warnings == []
    end

    test "is the web fallback, claiming no host and storing text", %{compiled: compiled} do
      assert compiled.declarations == %{
               hosts: [],
               url_action: :fetch,
               secrets: [],
               throttles: %{},
               cache: :text,
               web_fallback: true
             }

      refute compiled.actions.fetch.write
    end
  end

  describe "fetch — reading a page" do
    test "reads the page's main as markdown, links resolved against the page", %{module: module} do
      Req.Test.stub(Context, fn conn -> html(conn, @page) end)

      assert {:ok, %{"content" => @markdown, "format" => "text/markdown"}} = fetch(module, %{})
    end

    test "reads the body where there is no main or article", %{module: module} do
      Req.Test.stub(Context, fn conn ->
        html(conn, "<html><body><h2>Plain</h2><p>Text.</p></body></html>")
      end)

      assert {:ok, %{"content" => "## Plain\n\nText.\n"}} = fetch(module, %{})
    end

    @tag doc: """
         A page a browser fills in with JavaScript renders to no text here.
         It is answered as an empty page, which the cache keeps; a failure
         means such a page is refused, or answered as something it is not.
         """
    test "answers a page that renders to nothing as an empty page", %{module: module} do
      Req.Test.stub(Context, fn conn ->
        html(conn, ~s[<html><body><div id="app"></div><script>boot()</script></body></html>])
      end)

      assert {:ok, %{"content" => "\n", "format" => "text/markdown"}} = fetch(module, %{})
    end

    test "refuses a page larger than it reads, before reading it", %{module: module} do
      Req.Test.stub(Context, fn conn -> html(conn, String.duplicate("x", 5_000_001)) end)

      assert {:error, message} = fetch(module, %{})
      assert message =~ "is 5000001 bytes, over the 5000000 this script reads"
    end

    test "passes plain text and markdown through as they are", %{module: module} do
      Req.Test.stub(Context, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/markdown")
        |> Plug.Conn.send_resp(200, "# Already markdown\n")
      end)

      assert {:ok, %{"content" => "# Already markdown\n"}} = fetch(module, %{})
    end

    @tag doc: """
         This script stores text (`cache: :text`), so bytes it cannot read as a
         page are refused with a pointer at a script that stores files — never
         passed on, where the node's text guard would refuse them with less to
         go on.
         """
    test "refuses what is not a page, naming a script that stores files", %{module: module} do
      Req.Test.stub(Context, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("image/png")
        |> Plug.Conn.send_resp(200, <<137, 80, 78, 71>>)
      end)

      assert {:error, message} = fetch(module, %{})
      assert message =~ "is image/png, not a page this script reads"
      assert message =~ "cache: :file"
    end

    test "names the status for anything but 200 and 304", %{module: module} do
      Req.Test.stub(Context, fn conn -> Plug.Conn.send_resp(conn, 404, "") end)

      assert {:error, "https://docs.example.test/guide/start answered 404"} = fetch(module, %{})
    end

    test "answers the transport failure's own message", %{module: module} do
      Req.Test.stub(Context, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, message} = fetch(module, %{})
      assert message =~ "connection refused"
    end
  end

  describe "fetch — the change check" do
    test "answers an ETag as the validator, and sends it back as If-None-Match", %{module: module} do
      Req.Test.stub(Context, fn conn -> html(conn, @page, [{"etag", ~s("v1")}]) end)

      assert {:ok, %{"reference_validator" => ~s(etag:"v1")}} = fetch(module, %{})

      Req.Test.stub(Context, fn conn ->
        assert Plug.Conn.get_req_header(conn, "if-none-match") == [~s("v1")]
        Plug.Conn.send_resp(conn, 304, "")
      end)

      assert {:ok, %{"unchanged" => true}} =
               fetch(module, %{"reference_validator" => ~s(etag:"v1")})
    end

    test "falls back to Last-Modified, sent back as If-Modified-Since", %{module: module} do
      date = "Tue, 29 Sep 2026 07:00:00 GMT"
      Req.Test.stub(Context, fn conn -> html(conn, @page, [{"last-modified", date}]) end)

      assert {:ok, %{"reference_validator" => "last-modified:" <> ^date}} = fetch(module, %{})

      Req.Test.stub(Context, fn conn ->
        assert Plug.Conn.get_req_header(conn, "if-modified-since") == [date]
        Plug.Conn.send_resp(conn, 304, "")
      end)

      assert {:ok, %{"unchanged" => true}} =
               fetch(module, %{"reference_validator" => "last-modified:" <> date})
    end

    @tag doc: """
         The hash covers the markdown, not the HTML, so fetched-at keeps
         meaning "the content last changed": markup that churns while the text
         stands still answers unchanged. A failure on the second call means a
         page with no validator header is refetched as new at every refresh.
         """
    test "hashes the markdown where the server sends neither header", %{module: module} do
      Req.Test.stub(Context, fn conn -> html(conn, @page) end)

      assert {:ok, %{"reference_validator" => "sha256:" <> hex = validator}} = fetch(module, %{})
      assert hex == Base.encode16(:crypto.hash(:sha256, @markdown), case: :lower)

      Req.Test.stub(Context, fn conn ->
        html(conn, String.replace(@page, "<main>", ~s(<main class="new">)))
      end)

      assert {:ok, %{"unchanged" => true}} = fetch(module, %{"reference_validator" => validator})

      Req.Test.stub(Context, fn conn -> html(conn, String.replace(@page, "one", "uno")) end)

      assert {:ok, %{"content" => content}} =
               fetch(module, %{"reference_validator" => validator})

      assert content =~ "- uno"
    end

    test "answers unchanged when the server ignores the question but the ETag stands", %{
      module: module
    } do
      Req.Test.stub(Context, fn conn -> html(conn, @page, [{"etag", ~s("v1")}]) end)

      assert {:ok, %{"unchanged" => true}} =
               fetch(module, %{"reference_validator" => ~s(etag:"v1")})
    end
  end
end
