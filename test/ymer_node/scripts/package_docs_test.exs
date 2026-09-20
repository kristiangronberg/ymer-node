defmodule YmerNode.Scripts.PackageDocsTest do
  @moduledoc """
  Reads docs chunks off `_build`, so no database and `async: true`. Every
  promised package is a dependency of this project, so the chunks the cases
  read are the ones a release built from this checkout carries.
  """
  use ExUnit.Case, async: true

  alias YmerNode.Scripts.PackageDocs

  describe "names/0" do
    test "answers the promised packages by hex name, in the curated order" do
      assert PackageDocs.names() == [
               "req",
               "floki",
               "mdex",
               "typst",
               "nimble_csv",
               "sweet_xml",
               "saxy",
               "xlsx_reader",
               "elixlsx"
             ]
    end
  end

  describe "render/1" do
    test "opens with the package, the version this build carries and its modules" do
      assert {:ok, text} = PackageDocs.render("saxy")

      version = :saxy |> Application.spec(:vsn) |> List.to_string()
      assert String.starts_with?(text, "# saxy #{version}\n\n")
      assert text =~ "`Saxy.XML`, `Saxy`"
      assert text =~ "`YmerNode.Script`'s What a script may call"
    end

    test "renders the curated modules in order, as the guide renders its own" do
      assert {:ok, text} = PackageDocs.render("saxy")

      assert text =~ "\n# Saxy.XML\n"
      assert text =~ "\n# Saxy\n"
      assert text =~ "### characters(text)"
      assert offset(text, "\n# Saxy.XML\n") < offset(text, "\n# Saxy\n")
      refute text =~ "# Applications this release carries"
    end

    @tag doc: """
         Every name the list promises must render in this build: a module that
         stopped carrying docs, or moved at a line bump, refuses the whole page.
         A failure names the module in its detail — the fix is the curated list
         or the dependency line, never a partial page. `NimbleCSV.RFC4180` is
         the thin case: a generated module whose moduledoc is one line and whose
         functions carry no docs, so its page is a heading and that line.
         """
    test "renders every promised name" do
      for name <- PackageDocs.names() do
        assert {:ok, text} = PackageDocs.render(name), "#{name} did not render"
        assert text =~ ~r/^# #{name} \d/, "#{name} rendered without its version"
      end

      assert {:ok, text} = PackageDocs.render("nimble_csv")
      assert text =~ "\n# NimbleCSV.RFC4180\n"

      assert {:ok, text} = PackageDocs.render("typst")
      assert text =~ "and what a row cannot say are in `YmerNode.Script`'s What a script may call"
      assert text =~ "\n# Typst.Format\n"
      assert text =~ "### escape(text)"
      assert text =~ "\n# Typst.Format.Table.Vline\n"
    end

    test "refuses a name outside the list, naming every accepted one" do
      for name <- ["json", "context", "xmerl", "Saxy", ""] do
        assert {:error, {:unknown_package, detail}} = PackageDocs.render(name)
        assert detail =~ inspect(name)

        assert detail =~ Enum.join(PackageDocs.names(), ", ")
      end
    end
  end

  describe "version/1" do
    @tag doc: """
         The one call that reaches the nil clause: every name `render/1` accepts
         is a dependency this build loads, so a page never shows this string.
         A failure means the clause went — a bare `List.to_string/1` over the
         `nil` an unloaded application answers crashes where this names it.
         """
    test "names an application this VM has not loaded instead of crashing" do
      assert PackageDocs.version(:no_such_application) ==
               "(version unknown: application not loaded)"
    end
  end

  defp offset(text, phrase) do
    {offset, _length} = :binary.match(text, phrase)
    offset
  end
end
