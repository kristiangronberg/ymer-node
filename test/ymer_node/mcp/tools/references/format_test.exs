defmodule YmerNode.Mcp.Tools.References.FormatTest do
  @moduledoc """
  Builds `%Reference{}` structs in memory rather than through the repo: nothing
  here touches the database, so the module is `async: true`.

  Classifications are passed in as literals, which is the whole point of the
  module's signature: `Format` renders a classification and never derives one,
  so these cases can state exactly what the renderer was handed without a
  database or a set of declarations anywhere in sight.
  """
  use ExUnit.Case, async: true

  alias YmerNode.Mcp.Tools.References.Format
  alias YmerNode.References.Reference
  alias YmerNode.References.Sources

  @tracker %{name: "tracker", hosts: ["tracker.example.fi"], action: "issue"}
  @web %{source: "web", recipe: nil}

  defp reference(attrs) do
    struct(
      %Reference{
        id: 1,
        title: "A title",
        uri: "https://elixir-lang.org",
        fragment: "",
        tags: [],
        inserted_at: ~U[2026-09-08 10:00:00Z],
        updated_at: ~U[2026-09-08 11:00:00Z]
      },
      attrs
    )
  end

  describe "reference/2" do
    test "renders the source and recipe it is handed" do
      uri = "https://tracker.example.fi/browse/ABC-1"
      classification = Sources.classify(uri, [@tracker])
      formatted = Format.reference(reference(%{uri: uri}), classification)

      assert formatted.source == "tracker"
      assert formatted.recipe.params["script"] == "tracker"
      assert formatted.recipe.params["args"] == %{"url" => uri}
    end

    @tag doc: """
         The same reference formatted against no declarations carries `web` and
         no recipe — the retroactive property, seen from the response side: what
         a reference resolves to is a fact about the node's accepted scripts, not
         about the row. A failure means a source or recipe got stored somewhere.
         """
    test "the same reference carries web and no recipe when nothing claims its host" do
      uri = "https://tracker.example.fi/browse/ABC-1"

      formatted =
        reference(%{uri: uri})
        |> Format.reference(Sources.classify(uri, []))

      assert formatted.source == "web"
      refute Map.has_key?(formatted, :recipe)
    end

    test "timestamps are ISO-8601" do
      formatted = reference(%{}) |> Format.reference(@web)

      assert formatted.inserted_at == "2026-09-08T10:00:00Z"
      assert formatted.updated_at == "2026-09-08T11:00:00Z"
    end

    @tag doc: """
         The absent-when-empty wire contract: a blank fragment, a nil recipe, a
         nil description and empty tags are dropped rather than sent as keys
         holding nothing. A failure means a caller now has to distinguish "absent"
         from "present but empty" for every one of them.
         """
    test "blank fragment, empty tags, nil description and nil recipe are compacted away" do
      formatted = reference(%{description: nil, fragment: "", tags: []}) |> Format.reference(@web)

      refute Map.has_key?(formatted, :fragment)
      refute Map.has_key?(formatted, :tags)
      refute Map.has_key?(formatted, :description)
      refute Map.has_key?(formatted, :recipe)
      assert formatted.id == 1
      assert formatted.title == "A title"
    end

    test "a real fragment and real tags survive" do
      formatted =
        reference(%{fragment: "Configuration", tags: ["kept"]}) |> Format.reference(@web)

      assert formatted.fragment == "Configuration"
      assert formatted.tags == ["kept"]
    end
  end

  describe "classified/1" do
    test "renders an entry that carries its own classification" do
      entry = %{reference: reference(%{}), classification: @web}

      assert Format.classified(entry).source == "web"
    end
  end

  describe "find_hit/1" do
    test "a nil score formats as a plain reference; a real score rides along" do
      hit = %{reference: reference(%{}), classification: @web, score: nil}
      refute Map.has_key?(Format.find_hit(hit), :score)

      scored = %{reference: reference(%{}), classification: @web, score: 2}
      assert Format.find_hit(scored).score == 2
    end
  end
end
