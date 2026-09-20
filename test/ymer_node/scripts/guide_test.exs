defmodule YmerNode.Scripts.GuideTest do
  @moduledoc """
  Reads docs chunks off `_build`, so no database and `async: true`. The one
  compile here builds a module in memory and never on disk — the point of the
  refusal case, since a module with no beam file is the nearest a test can get
  to a release that stripped the chunk.
  """
  use ExUnit.Case, async: true

  alias YmerNode.Scripts.Guide
  alias YmerNode.Scripts.PackageDocs

  describe "render/1" do
    test "renders both modules, moduledoc first, entries in source order" do
      assert {:ok, text} = Guide.render()

      assert text =~ "# YmerNode.Script\n"
      assert text =~ "# YmerNode.Script.Context\n"
      assert text =~ "## Writing one"
      assert text =~ "## Types\n\n### action/0"
      assert text =~ "## Callbacks\n\n### description/0"
      assert text =~ "### request(context, options)"

      assert offset(text, "# YmerNode.Script\n") < offset(text, "# YmerNode.Script.Context\n")
      assert offset(text, "### action/0") < offset(text, "## Callbacks")

      assert offset(text, "### request(context, options)") <
               offset(text, "### secret(context, name)")
    end

    @tag doc: """
         Pins the things an author cannot write a working script without — the
         contract's callbacks, the action shape's `write` and `timeout` marks and
         the declarations' `hosts`/`url_action` semantics, which only the two
         typedocs carry, the two function docs — and the four sections the
         guide exists to add. A failure means a doc of `YmerNode.Script` lost
         one, or the renderer stopped rendering its kind, and every client
         reading `scripts guide` lost it with it.
         """
    test "carries the contract and the authoring sections" do
      assert {:ok, text} = Guide.render()

      for phrase <- [
            "use YmerNode.Script",
            "description/0",
            "run/3",
            "JSON-encodable",
            "or as a request body, never as the answer",
            "`write: true` says the action changes something outside this node",
            "capped by the runner.",
            "`hosts` are the hosts a reference is classified by",
            "action that accepts a uri whole under `url`",
            "The contract version this node speaks",
            "Read at compile time rather than checked by the compiler"
          ] do
        assert text =~ phrase
      end

      for section <- [
            "## Types\n\n### action/0",
            "### declarations/0",
            "## The loop",
            "## What a script may call",
            "## Secrets\n\nA script that reaches",
            "## Sharing a script"
          ] do
        assert text =~ section
      end
    end

    @tag doc: """
         Pins the table from job to package — one row per job, one package per
         row, the line the node follows in the last column — and the list
         beneath it of what a row cannot say, one item per package. A failure
         means a row lost its package or its line, the pointer at `scripts
         info` went, or an item or one of its sentences did: an author reading
         `scripts guide` then writes against a package the node never
         promised, or ships the silent wrong output the item exists to
         prevent.
         """
    test "maps each job to one package with its line, and points at info" do
      assert {:ok, text} = Guide.render()

      for row <- [
            "| Read XML — an RSS feed, a SOAP answer | sweet_xml: `SweetXml`, XPath over `:xmerl` | 0.7 |",
            "| Write XML — a SOAP envelope | saxy: `Saxy.XML`, then `Saxy.encode!/2` | 1.6 |",
            "| Read and write CSV | nimble_csv: `NimbleCSV.RFC4180`, or a separator variant " <>
              "`NimbleCSV.define/2` makes nested under the script's module — " <>
              "`NimbleCSV.define(__MODULE__.Semi, separator: \";\")`, never a bare name, " <>
              "which lands outside the script's tree and outlives it | 1.3 |",
            "| Read XLSX | xlsx_reader: `XlsxReader` | 0.8 |",
            "| Write XLSX | elixlsx: `Elixlsx` | 0.6 |",
            "| Read HTML into markdown | floki: `Floki` | 0.38 |",
            "| Write markdown, or turn it into what a system accepts | mdex: `MDEx` | 0.13 |",
            "| Write a PDF — a report other people read — from Typst markup, or its pages " <>
              "as PNG or SVG | typst: `Typst` | 0.4 |"
          ] do
        assert text =~ row
      end

      assert text =~ "with `scripts info <name>` — the name is the *Use* cell's first"
      assert text =~ "word, and `req` for Req —"
      assert text =~ "What a row cannot say:\n\n- **saxy** — "
      assert text =~ "emits a plain string as content raw"
      assert text =~ "\n- **xlsx_reader** — "
      assert text =~ "reads a whole-number cell back as a float"

      for phrase <- [
            "\n- **typst** — Render through the context:",
            "`Context.render_to_pdf(context, markup, bindings)`, or `render_to_png`",
            "The node's policy is underneath — the",
            "document's root is the files directory, so every path in the markup",
            "the fonts are scanned afresh on every render,",
            "many renders passes `cache_fonts: true` itself",
            "bindings: `Context.render_to_pdf(context, markup, [], cache_fonts: true)`",
            "directly goes around the policy: its root is the",
            "kept until the node restarts. The markup",
            "is an EEx template: text a system produced is handed in as a binding,",
            "literal `<%` in the markup is written `<%%`",
            "markup goes through `Typst.Format.escape/1`",
            "never escaped and never free text",
            "name four font families inside the package's native library — Libertinus",
            "Serif, New Computer Modern, New Computer Modern Math and DejaVu Sans",
            "Mono — and every font installed on the machine the node runs on, put",
            "sees the container's fonts, not the host machine's, and one the package",
            "ships beside its library falls back on the node",
            "find falls back silently, so a wrong name is a different-looking PDF",
            "A `@preview` import",
            "network error naming the package"
          ] do
        assert text =~ phrase
      end

      # The two facts this item stopped telling an author to act on. Both read
      # as advice a reader would follow, so their return would be silently
      # wrong rather than merely stale.
      refute text =~ "Pass `root_dir: Context.files_dir(context)` on every render"
      refute text =~ "`extra_fonts: [Path.join(Context.files_dir(context), \"fonts\")]`"

      assert text =~ "Erlang/OTP applications this release carries"
    end

    @tag doc: """
         Ties the table to `YmerNode.Scripts.PackageDocs`: the pointer sentence
         sends an author to `scripts info` with a row's *Use* cell's first word,
         so every such word must be a name the action accepts, and every name it
         accepts must have a row — `req` aside, promised in the sentence above
         the table. A failure means a row and the curated list drifted apart: an
         author is refused for the name the guide gave them, or `info` renders a
         package the guide never promised.
         """
    test "every row's package is a name info accepts, and every name but req has a row" do
      assert {:ok, text} = Guide.render()

      names =
        text
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "| "))
        |> Enum.reject(&(&1 =~ ~r/^\| (Job|---) \|/))
        |> Enum.map(fn row ->
          [_job, use_cell, _line] =
            row |> String.split("|", trim: true) |> Enum.map(&String.trim/1)

          use_cell |> String.split(":", parts: 2) |> hd()
        end)

      assert Enum.sort(names) == Enum.sort(PackageDocs.names() -- ["req"])
    end

    test "promises zone-aware DateTime and names the node's time zone" do
      assert {:ok, text} = Guide.render()

      assert text =~ "work with IANA zone names in every script"
      assert text =~ "so a script names zones, never the database module"
      assert text =~ "### time_zone(context)"
      assert text =~ "The node's time zone, as the IANA name of the zone this node runs in"
    end

    @tag doc: """
         The battery list opens both the Context moduledoc and its `t:t/0`
         typedoc, in the same words, so the guide carries it twice and an
         `assert` on it is satisfied by either. The `refute` is what makes the
         pair honest: a failure on it means one of the two sites was updated
         and the other left behind.
         """
    test "names the files directory among the batteries and renders its accessor" do
      assert {:ok, text} = Guide.render()

      assert text =~ "the node's time zone, the files directory and the"
      assert text =~ "Typst renders — provided by the node rather than declared by the script."
      refute text =~ "the node's time zone, the files directory — provided"
      assert text =~ "## Files\n"
      assert text =~ "### files_dir(context)"
      assert text =~ "The files directory — the one directory on this machine a script reads"
      assert text =~ "File.read!(Path.join(Context.files_dir(context), \"issues.xlsx\"))"
    end

    @tag doc: """
         The Typst section and the three renders are what a script author is
         given instead of the two keywords the item used to tell them to pass.
         A failure means the section left the moduledoc or a render stopped
         being documented — and an author reading `scripts guide` is back to
         calling the package directly, against the release's own directory.
         """
    test "carries the Typst section and renders the three render functions" do
      assert {:ok, text} = Guide.render()

      assert text =~ "## Typst\n"
      assert offset(text, "## Files\n") < offset(text, "## Typst\n")
      assert offset(text, "## Typst\n") < offset(text, "## The notebook\n")

      for phrase <- [
            "directory is the document's root, and the font store is built afresh for every",
            "script passes nothing and may override anything — a loop of many renders asks",
            "A render sees every font installed on the machine the node runs on, put there",
            "container has, not what the host machine has",
            "A script calling `Typst` itself goes around the policy, as one calling `Req`",
            "Two of the policy's options matter",
            ~S|### render_to_pdf(context, markup, bindings \\ [], options \\ [])|,
            ~S|### render_to_png(context, markup, bindings \\ [], options \\ [])|,
            ~S|### render_to_svg(context, markup, bindings \\ [], options \\ [])|
          ] do
        assert text =~ phrase
      end

      assert offset(text, "### request(context, options)") < offset(text, "### render_to_pdf(")
      assert offset(text, "### render_to_svg(") < offset(text, "### secret(context, name)")
    end

    test "leaves hidden and undocumented entries out" do
      assert {:ok, text} = Guide.render()

      refute text =~ "__using__"
      refute text =~ "__struct__"
    end

    @tag doc: """
         The one section the guide adds to the docs, and the only place a
         client learns which Erlang/OTP applications this node carries. A
         failure means the section left the end of the guide, or stopped naming
         what the running node has loaded. The applications asserted here are
         loaded in the test VM and in a release alike, which is why the case
         names them and never counts them. `xmerl` and every promised package,
         read from `PackageDocs.names/0`, are named because a script's calls
         stand on them: a failure on one of those legs means it left the
         release, and every script using its row fails at the run.
         """
    test "ends with the applications the running node has loaded" do
      assert {:ok, text} = Guide.render()

      heading = "# Applications this release carries\n"
      assert offset(text, heading) > offset(text, "# YmerNode.Script.Context\n")

      [_docs, section] = String.split(text, heading)

      # A promised package's hex name is its application name, which is what
      # the tail prints — so the promised legs are read off the list, never
      # copied from it.
      for application <- ["crypto", "eex", "ymer_node", "xmerl"] ++ PackageDocs.names() do
        assert section =~ "- `#{application}` "
      end

      # By name, not by rendered line: a line's closing backtick sorts after `_`.
      assert offset(section, "- `mdex` ") < offset(section, "- `mdex_native` ")

      # On the code path but not loaded: the tail is what the running node has
      # loaded, never everything the distribution ships.
      refute section =~ "- `ssh` "
      refute section =~ "\n# "
    end

    test "refuses whole when a module carries no docs, naming the build" do
      [{module, _binary}] =
        Code.compile_string("defmodule Script.GuideProbe do\n  @moduledoc \"in memory\"\nend\n")

      on_exit(fn ->
        :code.purge(module)
        :code.delete(module)
      end)

      assert {:error, {:docs_missing, detail}} = Guide.render([YmerNode.Script, module])
      assert detail =~ "Script.GuideProbe"
      assert detail =~ "strip_beams"
    end
  end

  describe "render_modules/1" do
    test "renders the modules alone, with no applications tail" do
      assert {:ok, text} = Guide.render_modules([YmerNode.Script.Context])

      assert String.starts_with?(text, "# YmerNode.Script.Context\n")
      assert text =~ "### time_zone(context)"
      refute text =~ "# Applications this release carries"
    end

    @tag doc: """
         The refusal `render/1` and `YmerNode.Scripts.PackageDocs` share: the
         first module without docs stops the whole render, so a package page can
         never be the modules that happened to carry docs. A failure means the
         renderer started skipping or rendering partially, and `scripts info`
         would answer a page that reads as the whole package.
         """
    test "refuses whole when a module carries no docs, naming the build" do
      [{module, _binary}] =
        Code.compile_string(
          "defmodule Script.GuideProbeModules do\n  @moduledoc \"in memory\"\nend\n"
        )

      on_exit(fn ->
        :code.purge(module)
        :code.delete(module)
      end)

      assert {:error, {:docs_missing, detail}} =
               Guide.render_modules([YmerNode.Script.Context, module])

      assert detail =~ "Script.GuideProbeModules"
      assert detail =~ "strip_beams"
    end
  end

  @tag doc: """
       The release strips every BEAM chunk it does not name, and the guide is
       read from the `Docs` chunk at the call. A failure means a release built
       from this config would refuse every `scripts guide` — the refusal case
       above shows what a client would meet.
       """
  test "the release keeps the Docs chunk the guide reads" do
    assert get_in(Mix.Project.config(), [:releases, :ymer_node, :strip_beams]) == [keep: ["Docs"]]
  end

  defp offset(text, phrase) do
    {offset, _length} = :binary.match(text, phrase)
    offset
  end
end
