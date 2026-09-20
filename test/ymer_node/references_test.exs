defmodule YmerNode.ReferencesTest do
  use YmerNode.DataCase

  alias YmerNode.References
  alias YmerNode.References.Reference

  doctest YmerNode.References

  defp reference!(attrs) do
    defaults = %{
      title: "untitled reference",
      uri: "https://example.com/#{System.unique_integer([:positive])}"
    }

    {:ok, reference} = References.create_reference(Map.merge(defaults, attrs))
    reference
  end

  describe "create_reference/1" do
    test "creates a reference" do
      assert {:ok, %Reference{id: id}} =
               References.create_reference(%{
                 title: "Elixir docs",
                 uri: "https://elixir-lang.org"
               })

      assert is_integer(id)
    end

    @tag doc: """
         A failure here means exact re-adds either fork the registry — the unique
         index missing, or a fragment stored as NULL, which SQLite treats as
         distinct — or surface as a raw changeset error the tool layer cannot
         turn into "use reference #N instead".
         """
    test "an exact (uri, fragment) duplicate returns the existing reference" do
      existing = reference!(%{uri: "https://example.com/page", fragment: "Setup"})

      assert {:error, {:duplicate, %Reference{id: id}}} =
               References.create_reference(%{
                 title: "Another name",
                 uri: "https://example.com/page",
                 fragment: "Setup"
               })

      assert id == existing.id
    end

    test "duplicate detection sees the trimmed uri and the defaulted fragment" do
      existing = reference!(%{uri: "https://example.com/page"})

      assert {:error, {:duplicate, %Reference{id: id}}} =
               References.create_reference(%{
                 title: "Second try",
                 uri: "  https://example.com/page  "
               })

      assert id == existing.id
    end

    test "the same uri with a different fragment is a distinct reference" do
      reference!(%{uri: "https://example.com/page", fragment: "Setup"})

      assert {:ok, %Reference{}} =
               References.create_reference(%{
                 title: "Teardown section",
                 uri: "https://example.com/page",
                 fragment: "Teardown"
               })
    end

    test "invalid attrs return the changeset" do
      assert {:error, %Ecto.Changeset{}} = References.create_reference(%{title: "E"})
    end
  end

  describe "get_reference/1" do
    test "returns the reference for integer and string ids" do
      reference = reference!(%{})

      assert {:ok, %Reference{id: id}} = References.get_reference(reference.id)
      assert id == reference.id
      assert {:ok, %Reference{}} = References.get_reference(Integer.to_string(reference.id))
    end

    test "returns not_found for missing and malformed ids" do
      assert {:error, :not_found} = References.get_reference(999_999)
      assert {:error, :not_found} = References.get_reference("banana")
    end
  end

  describe "update_reference/2" do
    test "updates the given fields" do
      reference = reference!(%{})

      assert {:ok, %Reference{description: "now routed"}} =
               References.update_reference(reference, %{description: "now routed"})
    end

    test "a concurrently deleted reference degrades to not_found" do
      reference = reference!(%{})
      {:ok, _deleted} = References.delete_reference(reference)

      assert {:error, :not_found} = References.update_reference(reference, %{title: "new title"})
    end
  end

  describe "delete_reference/1" do
    test "hard-deletes; a double delete degrades to not_found" do
      reference = reference!(%{})

      assert {:ok, %Reference{}} = References.delete_reference(reference)
      assert {:error, :not_found} = References.get_reference(reference.id)
      assert {:error, :not_found} = References.delete_reference(reference)
    end
  end

  describe "list_references/1" do
    test "tag filter is AND — every given tag must be present" do
      both = reference!(%{title: "both", tags: ["release", "notes"]})
      _one = reference!(%{title: "one", tags: ["release"]})

      assert [%Reference{id: id}] = References.list_references(tags: ["release", "notes"])
      assert id == both.id
      assert length(References.list_references(tags: ["release"])) == 2
      assert References.list_references(tags: ["release", "absent"]) == []
    end

    @tag doc: """
         The source filter runs over a value that is derived from the uri at read
         time, never stored — so a failure here means either the derivation moved
         or someone added a `source` column. Only the built-in tokens are
         exercised: a declared source needs an accepted script row, and
         `YmerNode.References.SourcesTest` covers that half with declarations
         passed explicitly.
         """
    test "source filter derives from the uri" do
      web = reference!(%{title: "web thing", uri: "https://elixir-lang.org/docs"})
      _file = reference!(%{title: "local note", uri: "/Users/k/notes.md"})

      assert [%Reference{id: id}] = References.list_references(source: "web")
      assert id == web.id

      assert [%Reference{title: "local note"}] = References.list_references(source: "file")
    end

    @tag doc: """
         Ordering runs in Elixir, not SQL: SQLite's `lower()` folds ASCII only,
         so a title-ordered list would put "Åland" in the wrong place under a SQL
         sort. A failure on the title leg means the sort moved into the query.
         """
    test "orders by downcased title by default, locale-correct" do
      reference!(%{title: "banana"})
      reference!(%{title: "Apple"})
      reference!(%{title: "ånger"})
      reference!(%{title: "Zebra"})

      assert ["Apple", "banana", "Zebra", "ånger"] =
               References.list_references() |> Enum.map(& &1.title)
    end

    @tag doc: """
         timestamps are second-precision, so back-to-back creates land in the
         same second and would tie; both rows are backdated to distinct past
         seconds so the recency order is deterministic. The second half covers
         `update_reference/2` bumping updated_at, which is what moves a row to
         the front. A failure means either the ordering key or the timestamp
         bump changed — check `sort_references/2` and the changeset's
         `timestamps` before adjusting the backdating.
         """
    test "orders by recency with :recent" do
      first = reference!(%{title: "first"})
      second = reference!(%{title: "second"})

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.update_all(from(r in Reference, where: r.id == ^second.id),
        set: [updated_at: DateTime.add(now, -120, :second)]
      )

      Repo.update_all(from(r in Reference, where: r.id == ^first.id),
        set: [updated_at: DateTime.add(now, -60, :second)]
      )

      assert [first.id, second.id] ==
               References.list_references(order: :recent) |> Enum.map(& &1.id)

      {:ok, touched} = References.update_reference(second, %{description: "touched"})

      assert [touched.id, first.id] ==
               References.list_references(order: :recent) |> Enum.map(& &1.id)
    end
  end
end
