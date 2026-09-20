defmodule YmerNode.Scripts.PackageDocs do
  @moduledoc """
  A promised package's own documentation, rendered from this release — what
  `scripts info <name>` answers.

  ## The guide stays a map

  `YmerNode.Script`'s What a script may call promises one package per job and
  says nothing about how to call it: the package documents itself, here, at the
  version this release carries. The node authors the promise, the line and
  [*what a row cannot say*](docs/glossary.md#what-a-row-cannot-say); the
  package authors its functions and its examples. A
  hand-written example would drift from the package at the next line bump,
  where a rendered `Docs` chunk cannot — it is compiled from the same source the
  release runs — and an author touching no format pays nothing, one that does
  pays one call.

  ## Curation is data

  `@packages` maps each promised name — the hex name the guide's table spells —
  to its OTP application and the modules an author needs: the entry points, not
  every module the package compiles. It is the one place a package's rendered
  set is decided, and a package bumped to a line whose modules moved is a change
  to this list. `YmerNode.Scripts.Guide.render_modules/1` does the rendering, so
  a package's page reads exactly as the guide does.

  ## Whole or refused

  A name outside the list is refused naming every accepted one — the refusal is
  the documentation for the call it declined. A module without docs refuses the
  whole answer naming the module and the release setting that keeps the chunk,
  as the guide does: a partial page would read as the whole package.
  """
  alias YmerNode.Scripts.Guide

  @packages [
    {"req", :req, [Req, Req.Response]},
    {"floki", :floki, [Floki]},
    {"mdex", :mdex, [MDEx]},
    {"typst", :typst,
     [
       Typst,
       Typst.Format,
       Typst.Format.Table,
       Typst.Format.Table.Header,
       Typst.Format.Table.Footer,
       Typst.Format.Table.Cell,
       Typst.Format.Table.Hline,
       Typst.Format.Table.Vline
     ]},
    {"nimble_csv", :nimble_csv, [NimbleCSV, NimbleCSV.RFC4180]},
    {"sweet_xml", :sweet_xml, [SweetXml]},
    {"saxy", :saxy, [Saxy.XML, Saxy]},
    {"xlsx_reader", :xlsx_reader, [XlsxReader]},
    {"elixlsx", :elixlsx, [Elixlsx, Elixlsx.Workbook, Elixlsx.Sheet]}
  ]

  @doc "Every name `render/1` accepts, in the curated list's order; the guide's table groups its rows by job."
  def names, do: Enum.map(@packages, fn {name, _app, _modules} -> name end)

  @doc """
  Renders one promised package: a header naming the package, the version the
  running release carries and the modules rendered, one line pointing back at
  the guide's table, then each curated module as the guide renders its own.

  Answers `{:ok, markdown}`; `{:error, {:unknown_package, detail}}` for a name
  outside `names/0`, the detail naming every accepted one; or the renderer's
  `{:error, {:docs_missing, detail}}`, naming the first module whose docs this
  build does not carry.
  """
  def render(name) when is_binary(name) do
    case List.keyfind(@packages, name, 0) do
      {^name, app, modules} -> render(name, app, modules)
      nil -> {:error, {:unknown_package, unknown(name)}}
    end
  end

  defp render(name, app, modules) do
    with {:ok, docs} <- Guide.render_modules(modules) do
      {:ok, header(name, app, modules) <> docs}
    end
  end

  defp header(name, app, modules) do
    "# #{name} #{version(app)}\n\n" <>
      "The package's own documentation, rendered from the docs this release carries " <>
      "at that version: #{Enum.map_join(modules, ", ", &"`#{inspect(&1)}`")}. What the " <>
      "node promises of it — the job it is for, and the line it follows — and what " <>
      "a row cannot say are in `YmerNode.Script`'s What a script may call (its " <>
      "table's row, or for Req the sentence above the table, and the list beneath " <>
      "the table), which `scripts guide` renders.\n\n"
  end

  # A release loads every application it carries at boot, and mix loads every
  # dependency, so the version is there whenever the modules above were; the
  # nil clause is what an unloaded application would answer, named rather
  # than crashed on.
  #
  # Public, and `@doc false`, ONLY so that nil clause is testable: every name
  # `render/1` accepts is a loaded dependency, so no call through it reaches
  # the clause. `YmerNode.Scripts.PackageDocsTest` is the reader.
  @doc false
  def version(app) when is_atom(app) do
    case Application.spec(app, :vsn) do
      nil -> "(version unknown: application not loaded)"
      vsn -> List.to_string(vsn)
    end
  end

  defp unknown(name) do
    "no promised package is named #{inspect(name)}; the names are " <>
      Enum.join(names(), ", ")
  end
end
