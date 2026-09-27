defmodule YmerNode.Scripts.BrowserService do
  @moduledoc """
  The node's half of the **browser service**: the Node program in
  `browser-service/` that a user starts on their own machine, outside the node,
  which runs Playwright code a script sends it — each browser call in a fresh
  browser context — and keeps the storage states.

  The browser, Playwright and Node.js stay out of the node, its image and its
  release: a browser is hundreds of megabytes that most nodes never use, and
  Playwright's own release cadence would become the node's. So the node owns
  four things and no more — where the service is, the token it sends there,
  how long a call may wait, and how a failure reads — and a script reaches the
  service only through `YmerNode.Script.Context.playwright/3`, never by URL.

  ## Where the service is

  `url/0`. A release reads `BROWSER_SERVICE_URL`; without it, a node inside its
  own image — where the bind marker is — reaches the host's loopback-bound
  service at `http://host.docker.internal:8013`, and a node on the host at
  `http://127.0.0.1:8013`. That default reaches on macOS Docker and on a host
  node; on Linux Docker it does not, and the variable is the way there. A VM
  that sets nothing — a script's own repository testing it under `runtime:
  false` — answers the host default, and its calls meet the test's stub
  rather than the network.

  ## The token

  Every request carries the service's token as `Authorization: Bearer`, and
  the service refuses one without it: a browser call's code runs in the
  service's own process with the privileges of whoever started it, and a
  loopback bind does not keep other programs out — every container on a Docker
  host reaches the host through `host.docker.internal`, as the node's image
  does. The token is the contents of a file only its owner can read,
  `~/.ymer-node/browser-service-token` unless `BROWSER_SERVICE_TOKEN_FILE`
  moves it, for the service and any node on the host alike, and whichever of
  them needs it first writes it: the file `0600`, and any directory it makes
  `0700`. A node inside its own image cannot read a file on the host, so a
  release there reads no file and sends the value of `BROWSER_SERVICE_TOKEN`,
  which wins wherever it is set. A node that cannot read the file sends no
  token, and neither does one that finds the file readable by others — that
  one logs a warning naming the `chmod` — and the service's refusal says where
  the token is. A request a plug answers — a test's stub — reaches no service,
  so the node never reads or writes the default file for one; a token or a
  file the configuration names is still sent.

  ## How long a call may wait

  What remains of the run's deadline, and nothing the script picks: the
  service is told that remainder less a margin, which leaves it time to stop
  the code, take the failure screenshot and answer before the node stops
  listening at the deadline itself. Connecting takes at most a second of the
  remainder, so a URL where nothing refuses and nothing answers reads as
  `:timeout` rather than `:unreachable`. A run with no time left answers
  `:timeout` and sends nothing. A longer browser flow raises its action's
  `timeout` key, up to the run's cap.

  ## The wire

  Every request goes through `YmerNode.Script.Context.request_options/0` — the
  node's Req policy, and in tests the one plug every script call is stubbed
  at — with the receive bound set per call. `POST /call` carries the code, its
  arguments, the storage state and whether to save it, the options handed to
  Playwright's `browser.newContext()`, whether to take the failure screenshot,
  and `bound_ms`; the service answers `{"ok": true, …}` or `{"ok": false,
  "error": {…}}`. Anything else is `:protocol`: when it carries the service's
  own `{"error": text}` — a request refused before any code ran — the text is
  the message, and otherwise the answer is taken for another program's.
  `GET /status` is what `status/0` reports.
  """
  alias YmerNode.Script.Context
  alias YmerNode.Scripts.BrowserService.Error

  require Logger

  @default_url "http://127.0.0.1:8013"

  # Time kept back from the service's bound: its failure screenshot and title,
  # taken together, are capped at half of it; the other half covers closing
  # the context, encoding the answer and its trip back.
  @margin 1_000

  # How long a request may take to connect. One fixed value, so every request
  # shares one connection pool rather than starting one per value.
  @connect_timeout 1_000

  # How long status/0 listens once connected: the route answers from memory,
  # and with the connect it stays within five seconds.
  @status_receive 4_000

  @kinds %{
    "code" => :code,
    "thrown" => :thrown,
    "storage" => :storage,
    "value" => :value,
    "timeout" => :timeout
  }

  # ─── Runtime configuration ──────────────────────────────────────────

  @doc """
  The browser service's URL (`config :ymer_node, YmerNode.Scripts.BrowserService,
  :url`), `#{@default_url}` when nothing sets it — § Where the service is. A
  trailing slash is dropped, since the service answers only its own paths.
  """
  def url do
    :ymer_node
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:url, @default_url)
    |> String.trim_trailing("/")
  end

  # ─── Public API ─────────────────────────────────────────────────────

  @doc """
  One browser call, bounded by `deadline` — the run's, as the
  `System.monotonic_time(:millisecond)` instant it falls at.
  `YmerNode.Script.Context.playwright/3` is the door a script uses, and its
  doc is where the options and the answer are described. `save_storage: true`
  without a `storage:` name raises `ArgumentError`: there is no name to save
  under, and no call is sent.
  """
  def call(deadline, code, options)
      when is_integer(deadline) and is_binary(code) and is_list(options) do
    options =
      Keyword.validate!(options,
        args: %{},
        storage: nil,
        save_storage: false,
        browser_context: %{},
        screenshot: true
      )

    if options[:save_storage] == true and is_nil(options[:storage]) do
      raise ArgumentError, "save_storage: true needs storage:, the name to save the state under"
    end

    # The connect comes out of the remainder too, so connect and receive
    # together end at the deadline.
    remaining = deadline - System.monotonic_time(:millisecond) - @connect_timeout

    if remaining - @margin <= 0 do
      {:error, Error.timeout("the run's deadline leaves no time for a browser call")}
    else
      body =
        options
        |> Map.new()
        |> Map.merge(%{code: code, bound_ms: remaining - @margin})

      :post |> request("/call", remaining, json: body) |> answer()
    end
  end

  @doc """
  What `scripts browser` reports: the URL, whether anything answered there,
  and — when the browser service did — its Playwright version, the Chromium
  its headless browser runs (or why none launched), the storage state names
  and the names an interactive window holds. When nothing answered,
  something that is not the service did, or the service refused the request —
  one without its token, say — `message` says what to do. Facts the node
  measured at the call, never a verdict.
  """
  def status do
    case request(:get, "/status", @status_receive) do
      {:ok,
       %Req.Response{
         status: 200,
         body:
           %{"playwright" => playwright, "storage_states" => states, "windows" => windows} =
               body
       }}
      when is_binary(playwright) and is_list(states) and is_list(windows) ->
        %{
          url: url(),
          answered: true,
          playwright: playwright,
          chromium: body["chromium"],
          launch_error: body["launch_error"],
          storage_states: states,
          windows: windows
        }

      {:ok, %Req.Response{status: status, body: %{"error" => text}}} when is_binary(text) ->
        %{url: url(), answered: true, message: Error.refused(url(), status, text).message}

      {:ok, %Req.Response{status: status}} ->
        %{url: url(), answered: true, message: Error.protocol(url(), "status #{status}").message}

      {:error, %Req.TransportError{reason: :timeout}} ->
        %{url: url(), answered: false, message: Error.unanswered(url()).message}

      {:error, _exception} ->
        %{url: url(), answered: false, message: Error.unreachable(url()).message}
    end
  end

  defp request(method, path, receive_timeout, options \\ []) do
    Context.request_options()
    |> Keyword.merge(options)
    |> Keyword.merge(
      method: method,
      url: url() <> path,
      connect_options: [timeout: @connect_timeout],
      receive_timeout: receive_timeout,
      retry: false
    )
    |> Keyword.merge(auth())
    |> Req.request()
  end

  defp auth do
    case token() do
      nil -> []
      token -> [auth: {:bearer, token}]
    end
  end

  # § The token: a configured value, else a configured file — `nil` inside the
  # image — else the file BROWSER_SERVICE_TOKEN_FILE names, which a node the
  # release configuration never ran for (dev, a consumer's live run) reads here,
  # else the default file, which a request a plug answers never reads.
  defp token do
    config = Application.get_env(:ymer_node, __MODULE__, [])

    cond do
      is_binary(config[:token]) -> config[:token]
      Keyword.has_key?(config, :token_file) -> read_token(config[:token_file])
      file = token_file_variable() -> read_token(file)
      stubbed?() -> nil
      true -> read_token(Path.expand("~/.ymer-node/browser-service-token"))
    end
  end

  defp token_file_variable do
    case System.get_env("BROWSER_SERVICE_TOKEN_FILE") do
      blank when blank in [nil, ""] -> nil
      path -> path
    end
  end

  defp stubbed?, do: Keyword.get(Context.request_options(), :plug) not in [nil, false]

  defp read_token(nil), do: nil

  defp read_token(path) do
    if not File.exists?(path), do: create_token_file(path)

    with {:ok, contents} <- File.read(path),
         :ok <- check_mode(path) do
      contents |> String.trim() |> nonblank()
    else
      _unread -> nil
    end
  end

  # The rule `YmerNode.Secrets` and the service's own reader follow: a file
  # any group or other bit can read is refused. The service rechecks the file
  # it reads on every request, so this warning is what remains visible when
  # the node's file is not the service's.
  defp check_mode(path) do
    with {:ok, %File.Stat{mode: mode}} <- File.stat(path) do
      if Bitwise.band(mode, 0o077) == 0 do
        :ok
      else
        octal = mode |> Bitwise.band(0o777) |> Integer.to_string(8)

        Logger.warning(
          "#{path} is readable by others (mode #{octal}): run chmod 600 #{path}. " <>
            "No token is sent to the browser service until then."
        )

        {:error, :permissive}
      end
    end
  end

  defp nonblank(""), do: nil
  defp nonblank(token), do: token

  # Written whole to a neighbouring file, then linked into place: a reader
  # never meets half a token, and a process that loses the race to create it
  # keeps the winner's. OTP has no create-with-mode call, so the neighbour is
  # created empty and chmodded 0600 before a byte of the token reaches it, as
  # `YmerNode.Secrets` writes its file. Its name is random rather than a
  # `System.unique_integer/1`, which is unique within one VM only: two nodes
  # starting together can draw the same one, and a second writer truncating a
  # neighbour already linked into place would empty the token. A failure
  # leaves no token behind, and the read after it sends none.
  defp create_token_file(path) do
    suffix = 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    temporary = "#{path}.#{suffix}.tmp"
    token = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    try do
      with :ok <- make_directory(Path.dirname(path)),
           :ok <- File.write(temporary, ""),
           :ok <- File.chmod(temporary, 0o600),
           :ok <- File.write(temporary, token <> "\n") do
        File.ln(temporary, path)
      end
    after
      File.rm(temporary)
    end
  end

  # Every directory this call makes is 0700, as the service's are; one that
  # already exists keeps its mode, since it may not be the node's to change.
  defp make_directory(directory) do
    missing = missing_directories(directory, [])

    with :ok <- File.mkdir_p(directory) do
      Enum.reduce_while(missing, :ok, &restrict_directory/2)
    end
  end

  defp missing_directories(directory, missing) do
    parent = Path.dirname(directory)

    if File.dir?(directory) or parent == directory,
      do: missing,
      else: missing_directories(parent, [directory | missing])
  end

  defp restrict_directory(directory, :ok) do
    case File.chmod(directory, 0o700) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  defp answer({:ok, %Req.Response{status: 200, body: %{"ok" => true} = body}}) do
    case body do
      %{"value" => value, "url" => page_url, "title" => title, "duration_ms" => duration}
      when is_binary(page_url) and is_binary(title) and is_integer(duration) ->
        {:ok, %{value: value, url: page_url, title: title, duration_ms: duration}}

      _other ->
        {:error, Error.protocol(url(), "a success without its fields")}
    end
  end

  defp answer({:ok, %Req.Response{status: 200, body: %{"ok" => false, "error" => error}}})
       when is_map(error) do
    with {:ok, kind} <- Map.fetch(@kinds, error["kind"]),
         {:ok, screenshot} <- decode_screenshot(error["screenshot"]) do
      {:error,
       %Error{
         kind: kind,
         name: error["name"],
         message: error["message"],
         call_log: error["call_log"] || [],
         url: error["url"],
         title: error["title"],
         screenshot: screenshot
       }}
    else
      _unknown -> {:error, Error.protocol(url(), "a failure of no known kind")}
    end
  end

  defp answer({:ok, %Req.Response{status: status, body: %{"error" => text}}})
       when is_binary(text),
       do: {:error, Error.refused(url(), status, text)}

  defp answer({:ok, %Req.Response{status: status}}),
    do: {:error, Error.protocol(url(), "status #{status}")}

  defp answer({:error, %Req.TransportError{reason: :timeout}}),
    do: {:error, Error.timeout("the browser service did not answer before the run's deadline")}

  defp answer({:error, _exception}), do: {:error, Error.unreachable(url())}

  defp decode_screenshot(nil), do: {:ok, nil}
  defp decode_screenshot(encoded) when is_binary(encoded), do: Base.decode64(encoded)
  defp decode_screenshot(_other), do: :error
end
