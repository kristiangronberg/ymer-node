defmodule Script.Hex do
  @moduledoc """
  Packages on hex.pm — the node's worked example of a script.

  It is here to be read as much as to be run. Between them its two actions
  exercise every part of the contract a script can carry: a read action with a
  required argument, a URL action that claims a host and so supplies the fetch
  recipe references hands out, a host claim, and no secret at all.

  ## The two actions are different kinds

  `package` takes a name and builds the API url itself. `fetch` takes a url
  whole and is the one action `declarations/0` names as the `url_action`, which
  is what lets a reference pointing anywhere on `hex.pm` resolve to a `scripts
  run` call on this script. A script that claims a host must have exactly one
  such action, and its schema must declare a `url` property — the node refuses
  the script otherwise.

  Both are `write: false`. Nothing here changes anything, on hex.pm or here, and
  a worker reading the mark can act without asking.

  ## What it does not do

  No authentication: hex.pm's read API needs none, which is why it makes a good
  example — an example that needed a secret would teach the secret machinery
  instead of the contract. No retry: the node's `Req` options already turn Req's
  own retrying off, because a run has a deadline and a retry inside it spends
  that deadline without telling anyone.
  """
  use YmerNode.Script

  # Written out rather than assumed: `use YmerNode.Script` stamps the contract
  # and nothing else, so a script names the batteries it reaches for. That is
  # the line to copy when writing your own.
  alias YmerNode.Script.Context

  @api "https://hex.pm/api/packages/"

  @impl true
  def description, do: "Packages on hex.pm: metadata, versions, links and downloads"

  @impl true
  def actions do
    %{
      package: %{
        description: "One package's metadata by name",
        properties: %{
          "name" => %{
            "type" => "string",
            "description" => "The package name as it appears on hex.pm, e.g. \"req\"."
          }
        },
        required: ["name"],
        write: false
      },
      fetch: %{
        description: "Any hex.pm url, resolved to the package it names",
        properties: %{
          "url" => %{
            "type" => "string",
            "description" => "A hex.pm url — a package page, or an API url."
          }
        },
        required: ["url"],
        write: false
      }
    }
  end

  @impl true
  def declarations, do: %{hosts: ["hex.pm"], url_action: :fetch, secrets: []}

  @impl true
  # `URI.encode/1` keeps the reserved characters, `/` among them, so a name
  # carrying one would silently address a different path. The unreserved-only
  # predicate is what makes the name a single path segment.
  def run(:package, %{"name" => name}, context) do
    get(context, @api <> URI.encode(name, &URI.char_unreserved?/1))
  end

  def run(:fetch, %{"url" => url}, context) do
    case package_name(url) do
      {:ok, name} -> run(:package, %{"name" => name}, context)
      :error -> {:error, "not a hex.pm package url: #{url}"}
    end
  end

  # The host first, compared downcased: the references seam hands this action
  # out for hex.pm uris, but `scripts run` takes any url, and another host's
  # `/packages/<name>` is not hex.pm's `<name>`. Then the path — both the human
  # page and the API url carry the name in the same position, so one rule reads
  # either: /packages/<name> and /api/packages/<name>. Anything else is refused
  # rather than guessed at — a wrong guess would answer a different package's
  # metadata as though it were the right one.
  defp package_name(url) do
    case URI.parse(url) do
      %URI{host: host, path: path} when is_binary(host) and is_binary(path) ->
        if String.downcase(host) == "hex.pm", do: path_name(path), else: :error

      _other ->
        :error
    end
  end

  defp path_name("/packages/" <> rest), do: first_segment(rest)
  defp path_name("/api/packages/" <> rest), do: first_segment(rest)
  defp path_name(_other), do: :error

  defp first_segment(rest) do
    case rest |> String.split("/", parts: 2) |> hd() do
      "" -> :error
      name -> {:ok, name}
    end
  end

  defp get(context, url) do
    case Context.request(context, url: url) do
      {:ok, %{status: 200, body: body}} -> {:ok, summarise(body)}
      {:ok, %{status: 404}} -> {:error, "no such package on hex.pm"}
      {:ok, %{status: status}} -> {:error, "hex.pm answered #{status}"}
      {:error, exception} -> {:error, Exception.message(exception)}
    end
  end

  # A summary rather than the whole body: hex.pm's package payload runs to
  # thousands of bytes, most of it every release ever made, and the answer here
  # goes into a worker's context window.
  defp summarise(body) when is_map(body) do
    %{
      "name" => body["name"],
      "description" => get_in(body, ["meta", "description"]),
      "licenses" => get_in(body, ["meta", "licenses"]),
      "links" => get_in(body, ["meta", "links"]),
      "latest_version" => body["latest_stable_version"] || body["latest_version"],
      "downloads" => body["downloads"],
      "html_url" => body["html_url"]
    }
  end

  defp summarise(body), do: %{"body" => body}
end
