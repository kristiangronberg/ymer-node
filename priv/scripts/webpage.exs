defmodule Script.Webpage do
  @moduledoc """
  Any web page, read as markdown — the node's web fallback, and its worked
  example of a URL action that fills the cache.

  It is here to be read as much as to be run. `declarations/0` marks it the web
  fallback: every http(s) reference whose host no other accepted script claims
  resolves to its `fetch`, and a script that claims a host exactly still wins
  there. It claims no host itself.

  ## The answer the cache stores

  `fetch` answers a map the node stores as the reference's cache entry:
  `content`, the page as markdown; `format`, what the content is; and
  `reference_validator`, a string only this script reads. The node keeps the
  validator beside the entry and hands it back on the next fetch under
  `reference_validator`, so the script can ask whether anything changed
  instead of fetching the page again.

  ## The change check

  The validator says which question to ask:

  - `etag:<value>` — the server sent an `ETag`, so the next fetch sends it
    back as `If-None-Match`;
  - `last-modified:<value>` — the server sent only `Last-Modified`, so the
    next fetch sends `If-Modified-Since`;
  - `sha256:<hex>` — the server sent neither, so the next fetch converts the
    page and compares the markdown's hash.

  A `304`, or a fresh validator equal to the one handed in, answers
  `%{"unchanged" => true}`, and the node then only notes that it checked.
  Hashing the markdown rather than the HTML is deliberate: a page whose
  markup churns while its text stands still keeps its fetched-at.

  ## What it reads

  HTML becomes markdown on a best-effort basis: headings, paragraphs, lists,
  links (resolved against the page), emphasis, code and quotes. The page's
  `main` is read where it has one, else its `article`, else its `body`, and
  scripts, styles, navigation, headers, footers and forms are left out. A page
  served as `text/plain` or `text/markdown` passes through as it is. Anything
  else — an image, a PDF, a spreadsheet — is refused with a pointer at a script
  that stores files, because this one stores text. A page larger than 5 MB is
  refused before it is read; a page that renders to no text at all — a shell
  a browser fills in with JavaScript — is answered as the empty page it is.

  The reference's fragment is not read: the whole page is cached for each
  reference, and a reader finds the section in it.
  """
  use YmerNode.Script

  alias YmerNode.Script.Context

  @dropped "script, style, nav, header, footer, noscript, template, svg, form, iframe"

  # The largest page read, in bytes as served: above it, reading and converting
  # the page costs more than a reader of a cached page gains.
  @page_limit 5_000_000

  @impl true
  def description, do: "Any web page, read as markdown — the web fallback for unclaimed hosts"

  @impl true
  def actions do
    %{
      fetch: %{
        description: "One web page as markdown, with a change check",
        properties: %{
          "url" => %{
            "type" => "string",
            "description" => "An http(s) url."
          },
          "reference_validator" => %{
            "type" => "string",
            "description" =>
              "The reference_validator the last fetch answered; given, the page is " <>
                "answered as unchanged when the server says it has not changed."
          }
        },
        required: ["url"],
        write: false
      }
    }
  end

  @impl true
  def declarations do
    %{hosts: [], url_action: :fetch, secrets: [], cache: :text, web_fallback: true}
  end

  @impl true
  def run(:fetch, %{"url" => url} = args, context) do
    given = args["reference_validator"]
    options = [url: url, headers: conditional(given), decode_body: false]

    case Context.request(context, options) do
      {:ok, %{status: 304}} -> {:ok, %{"unchanged" => true}}
      {:ok, %{status: 200, body: body}} when byte_size(body) > @page_limit -> too_large(url, body)
      {:ok, %{status: 200} = response} -> answer(response, url, given)
      {:ok, %{status: status}} -> {:error, "#{url} answered #{status}"}
      {:error, exception} -> {:error, Exception.message(exception)}
    end
  end

  defp too_large(url, body),
    do: {:error, "#{url} is #{byte_size(body)} bytes, over the #{@page_limit} this script reads"}

  defp conditional("etag:" <> etag), do: [{"if-none-match", etag}]
  defp conditional("last-modified:" <> date), do: [{"if-modified-since", date}]
  defp conditional(_none_or_hash), do: []

  # A server may ignore the conditional request and answer the page whole; a
  # fresh validator equal to the one handed in still means nothing changed.
  defp answer(response, url, given) do
    with {:ok, markdown} <- markdown(response, url) do
      case validator(response, markdown) do
        ^given ->
          {:ok, %{"unchanged" => true}}

        fresh ->
          {:ok,
           %{"content" => markdown, "format" => "text/markdown", "reference_validator" => fresh}}
      end
    end
  end

  defp validator(response, markdown) do
    cond do
      etag = header(response, "etag") -> "etag:" <> etag
      modified = header(response, "last-modified") -> "last-modified:" <> modified
      true -> "sha256:" <> Base.encode16(:crypto.hash(:sha256, markdown), case: :lower)
    end
  end

  defp header(response, name) do
    case Req.Response.get_header(response, name) do
      [value | _rest] -> value
      [] -> nil
    end
  end

  defp markdown(response, url) do
    case content_type(response) do
      type when type in ["text/html", "application/xhtml+xml"] ->
        {:ok, html_to_markdown(response.body, url)}

      type when type in ["text/plain", "text/markdown"] ->
        {:ok, response.body}

      type ->
        {:error,
         "#{url} is #{type}, not a page this script reads — a script that stores " <>
           "files (cache: :file) serves it"}
    end
  end

  defp content_type(response) do
    case header(response, "content-type") do
      nil -> "text/html"
      value -> value |> String.split(";") |> hd() |> String.trim() |> String.downcase()
    end
  end

  # ─── HTML into markdown ─────────────────────────────────────────────

  defp html_to_markdown(html, url) do
    document =
      case Floki.parse_document(html) do
        {:ok, document} -> document
        {:error, _reason} -> []
      end

    document
    |> Floki.filter_out(@dropped)
    |> readable()
    |> render(URI.parse(url))
    |> tidy()
  end

  defp readable(document) do
    Enum.find_value(["main", "article", "body"], document, fn selector ->
      case Floki.find(document, selector) do
        [element | _rest] -> [element]
        [] -> nil
      end
    end)
  end

  # Block elements stand apart with blank lines around them; `tidy/1` folds the
  # runs of blank lines that nesting leaves behind.
  defp render(nodes, base) when is_list(nodes), do: Enum.map_join(nodes, &render(&1, base))
  defp render(text, _base) when is_binary(text), do: String.replace(text, ~r/\s+/, " ")
  defp render({:comment, _text}, _base), do: ""
  defp render({:pi, _target, _attrs}, _base), do: ""
  defp render({:doctype, _name, _public, _system}, _base), do: ""

  defp render({<<?h, level>>, _attrs, children}, base) when level in ?1..?6,
    do: block(String.duplicate("#", level - ?0) <> " " <> inline(children, base))

  defp render({"p", _attrs, children}, base), do: block(inline(children, base))
  defp render({"br", _attrs, _children}, _base), do: "\n"
  defp render({"hr", _attrs, _children}, _base), do: block("---")
  defp render({"pre", _attrs, children}, _base), do: block("```\n#{Floki.text(children)}\n```")
  defp render({"code", _attrs, children}, _base), do: "`" <> Floki.text(children) <> "`"

  defp render({tag, _attrs, children}, base) when tag in ["strong", "b"],
    do: "**#{inline(children, base)}**"

  defp render({tag, _attrs, children}, base) when tag in ["em", "i"],
    do: "_#{inline(children, base)}_"

  defp render({"a", attrs, children}, base), do: link(attrs, inline(children, base), base)
  defp render({"ul", _attrs, children}, base), do: list(children, base, fn _n -> "- " end)
  defp render({"ol", _attrs, children}, base), do: list(children, base, &"#{&1}. ")
  defp render({"blockquote", _attrs, children}, base), do: quote_block(render(children, base))
  defp render({_tag, _attrs, children}, base), do: render(children, base)

  defp inline(children, base),
    do: children |> render(base) |> String.replace(~r/\s+/, " ") |> String.trim()

  defp block(text), do: "\n\n" <> text <> "\n\n"

  defp link(attrs, text, base) do
    case List.keyfind(attrs, "href", 0) do
      {"href", href} when text != "" -> "[#{text}](#{URI.merge(base, href)})"
      _no_target -> text
    end
  end

  defp list(children, base, marker) do
    items = for {"li", _attrs, item} <- children, do: inline(item, base)

    items
    |> Enum.with_index(1)
    |> Enum.map_join("\n", fn {item, n} -> marker.(n) <> item end)
    |> block()
  end

  defp quote_block(text) do
    text
    |> String.trim()
    |> String.split("\n")
    |> Enum.map_join("\n", &String.trim_trailing("> " <> &1))
    |> block()
  end

  defp tidy(markdown) do
    markdown
    |> String.split("\n")
    |> Enum.map_join("\n", &String.trim_trailing/1)
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
    |> Kernel.<>("\n")
  end
end
