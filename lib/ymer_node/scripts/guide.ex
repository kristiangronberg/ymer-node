defmodule YmerNode.Scripts.Guide do
  @moduledoc """
  The text `scripts guide` renders — the script contract and the batteries a
  script is handed — read at the call from the docs the release keeps.

  ## One home

  What a script must implement and what it is handed are written once, as the
  moduledocs of `YmerNode.Script` and `YmerNode.Script.Context` and the docs
  beneath them, and this module renders those bytes: a client reading the guide
  and a developer reading the published docs read the same text, and a contract
  change moves one text. `Code.fetch_docs/1` is the reader, which is why the
  release keeps the BEAM `Docs` chunk that `mix release` strips by default —
  `strip_beams: [keep: ["Docs"]]` in `mix.exs`, and the one reason it is there.

  One section is the guide's own, and it comes last: *Applications this release
  carries*, read from the running node at the call. A release carries only the
  Erlang/OTP applications its dependencies need, and that set moves with every
  release line, so a list written in the docs would be a copy nobody keeps in
  step — and a client reaches the guide alone, so the list has to be in it.

  The rendering half stands on its own as `render_modules/1`, with no tail:
  `YmerNode.Scripts.PackageDocs` renders a promised package's docs through it,
  so a package's page reads exactly as the guide does and carries the
  applications list once, in the guide, rather than at the end of every answer.

  ## Whole or refused

  A build without the chunk is answered with a refusal naming the build, never
  a partial guide: `render/1` stops at the first module whose docs are missing
  and renders none of them. A dev checkout runs from `_build/dev`, where the
  chunk always exists.

  ## The shape

  One markdown text. Each module contributes its name as a heading, its
  moduledoc, then its documented types, callbacks and functions — grouped in
  that order, each group sorted by line in the source rather than by name, so
  the text reads the way its author laid it out — under a heading carrying the
  signature. Hidden docs (`@doc false`) and undocumented entries are left out,
  as the published docs leave them out.
  """
  alias YmerNode.Script

  @modules [Script, Script.Context]

  @kinds [type: "Types", callback: "Callbacks", function: "Functions"]

  @doc """
  Renders the guide over `modules` — the two contract modules by default — and
  ends it with the applications the running node has loaded.

  Answers `{:ok, markdown}`, or `{:error, {:docs_missing, detail}}` naming the
  first module whose docs this build does not carry.
  """
  def render(modules \\ @modules) when is_list(modules) do
    with {:ok, docs} <- render_modules(modules) do
      {:ok, docs <> "\n" <> applications()}
    end
  end

  @doc """
  Renders the docs of `modules` alone — each module's name as a heading, its
  moduledoc, then its documented types, callbacks and functions — with no
  applications tail. `render/1` is this plus the tail; `YmerNode.Scripts.PackageDocs`
  is this under a header of its own.

  Answers `{:ok, markdown}`, or `{:error, {:docs_missing, detail}}` naming the
  first module whose docs this build does not carry, rendering none of them.
  """
  def render_modules(modules) when is_list(modules) do
    case Enum.reduce_while(modules, {:ok, []}, &collect/2) do
      {:ok, parts} -> {:ok, parts |> Enum.reverse() |> Enum.join("\n")}
      {:error, _reason} = error -> error
    end
  end

  # A release's boot loads every application the release carries but the remote
  # shell's, so in a release this is the set a script's call meets.
  defp applications do
    lines =
      Application.loaded_applications()
      |> Enum.sort_by(fn {name, _description, _version} -> name end)
      |> Enum.map(fn {name, _description, version} -> "- `#{name}` #{version}" end)

    "# Applications this release carries\n\n" <>
      "Read from the running node when this guide was rendered, not from the docs " <>
      "above. An application missing here is not in this release, and a call into " <>
      "it fails at the run; which of these a script may rely on across releases is " <>
      "`YmerNode.Script`'s What a script may call.\n\n" <> Enum.join(lines, "\n")
  end

  defp collect(module, {:ok, parts}) do
    case Code.fetch_docs(module) do
      {:docs_v1, _anno, :elixir, _format, %{"en" => moduledoc}, _meta, docs} ->
        {:cont, {:ok, [render_module(module, moduledoc, docs) | parts]}}

      other ->
        {:halt, {:error, {:docs_missing, missing(module, other)}}}
    end
  end

  defp missing(module, reason) do
    "this build carries no docs for #{inspect(module)} (#{inspect(reason)}): the " <>
      "release was built without `strip_beams: [keep: [\"Docs\"]]`, which is what " <>
      "the guide is rendered from"
  end

  defp render_module(module, moduledoc, docs) do
    documented =
      for {{kind, name, arity}, anno, signature, %{"en" => doc}, _meta} <- docs,
          Keyword.has_key?(@kinds, kind),
          do: {kind, anno, heading(name, arity, signature), doc}

    sections =
      for {kind, title} <- @kinds,
          entries = entries(documented, kind),
          entries != [],
          do: "## #{title}\n\n" <> Enum.map_join(entries, "\n", &entry/1)

    Enum.join(["# #{inspect(module)}\n\n#{moduledoc}" | sections], "\n")
  end

  defp entries(documented, kind) do
    documented
    |> Enum.filter(fn {entry_kind, _anno, _heading, _doc} -> entry_kind == kind end)
    |> Enum.sort_by(fn {_kind, anno, _heading, _doc} -> anno end)
  end

  defp entry({_kind, _anno, heading, doc}), do: "### #{heading}\n\n#{doc}"

  # Types and callbacks carry no signature in the chunk, so they read as
  # `name/arity`; a function reads as its head.
  defp heading(name, arity, []), do: "#{name}/#{arity}"
  defp heading(_name, _arity, [signature | _rest]), do: signature
end
