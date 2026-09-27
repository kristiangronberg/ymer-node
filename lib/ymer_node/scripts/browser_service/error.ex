defmodule YmerNode.Scripts.BrowserService.Error do
  @moduledoc """
  A browser call's failure — the exception `YmerNode.Script.Context.playwright/3`
  answers as `{:error, exception}`, the way `YmerNode.Scripts.Throttle.Error`
  is what `YmerNode.Script.Context.request/2` answers for a refused request: a
  script matches on `kind`, or hands the exception back unchanged and the run's
  answer shows its message.

  `kind` is one of seven. Five come from the browser service:

    * `:code` — the text is not a function;
    * `:thrown` — a Playwright error, from the function or from opening the
      page it runs on, or the script's own check, which no field tells apart;
    * `:storage` — the storage state named is unknown or refused, or the call
      asked to save it while an interactive window held the name or after one
      opened on it;
    * `:value` — the returned value does not survive JSON;
    * `:timeout` — the call's bound passed, or the run's deadline left no time.

  Two are the node's own: `:unreachable`, nothing answered at the service's
  URL, and `:protocol`, an answer outside the service's contract — another
  program's, or the service's own refusal of a request it could not run, which
  carries the service's text.

  `name` and `message` are Playwright's, or the service's own; `call_log` is
  Playwright's call log as a list of lines. `url` and `title` are where the page
  stood when the code stopped. `screenshot` is a PNG of the viewport, taken on
  `:thrown` and `:timeout` when a page exists — not when opening it failed —
  unless the call asked for none: raw bytes, which the script decides whether
  to keep, in the files directory for instance.
  """
  defexception [:kind, :name, :message, :call_log, :url, :title, :screenshot]

  @impl true
  def message(%__MODULE__{kind: kind, message: message}),
    do: "browser call failed (#{kind}): #{message}"

  @doc """
  Nothing answered at `url`: the refusal names the start command, where the
  first-time setup lives, and the variable for a service that runs elsewhere.
  """
  def unreachable(url) when is_binary(url) do
    %__MODULE__{
      kind: :unreachable,
      message:
        "nothing answers at #{url}. In a checkout of " <>
          "https://github.com/kristiangronberg/ymer-node, run `npm start` in " <>
          "browser-service/ — first-time setup is the README's \"The browser service\" " <>
          "section — or point BROWSER_SERVICE_URL at a browser service that runs elsewhere",
      call_log: []
    }
  end

  @doc """
  Nothing answered at `url` in the time `status` gives it: a service there may
  be relaunching its browser, which its status waits for, so the refusal says
  to ask again before it names the start command.
  """
  def unanswered(url) when is_binary(url) do
    %__MODULE__{
      kind: :unreachable,
      message:
        "#{url} did not answer within five seconds. A browser service relaunching " <>
          "its browser can take that long, so ask again in a moment; if none is " <>
          "running, " <> unreachable(url).message,
      call_log: []
    }
  end

  @doc "Something answered at `url`, but neither with the browser service's contract nor with its `error` text."
  def protocol(url, detail) when is_binary(url) and is_binary(detail) do
    %__MODULE__{
      kind: :protocol,
      message:
        "#{url} answered, but not as the browser service (#{detail}): another program " <>
          "may hold the port, and BROWSER_SERVICE_URL points the node at the service's own",
      call_log: []
    }
  end

  @doc """
  The browser service answered `status` with its own `error` text rather than
  a result: a request it refused before any code ran — a field of the wrong
  shape, a `Host` it does not serve, no token or another than its own — or a
  fault of its own. The text is the service's, and says what to fix.
  """
  def refused(url, status, text) when is_binary(url) and is_integer(status) and is_binary(text) do
    %__MODULE__{
      kind: :protocol,
      message: "#{url} refused the request (status #{status}): #{text}",
      call_log: []
    }
  end

  @doc "The run's deadline passed, or left no time to send the call."
  def timeout(message) when is_binary(message),
    do: %__MODULE__{kind: :timeout, message: message, call_log: []}
end
