defmodule YmerNode.References.CacheEntryTest do
  @moduledoc """
  Writes rows straight through the schema, beneath `YmerNode.References.Cache`:
  what is pinned here is the table's own rules — one cache entry per
  reference, a body or a path, the target it was fetched for, and the
  cascade — which hold whatever wrote the row.
  """
  use YmerNode.DataCase

  alias YmerNode.References
  alias YmerNode.References.CacheEntry

  describe "the cache_entries table" do
    test "keeps a text entry's body and its stamps" do
      reference = reference!()
      entry = entry!(reference, %{body: "# Page\n"})

      assert %CacheEntry{body: "# Page\n", path: nil, script: "webpage"} =
               Repo.get!(CacheEntry, entry.id)
    end

    @tag doc: """
         A page that renders to nothing is a page, and its cache entry keeps
         an empty body. A failure means the changeset casts `""` to nil, and
         the row then holds neither a body nor a path — the database refuses
         it, and the fetch that produced it raises instead of being kept.
         """
    test "keeps an empty or blank body as a body" do
      for body <- ["", "\n"] do
        reference = reference!()
        entry = entry!(reference, %{body: body})

        assert %CacheEntry{body: ^body, path: nil} = Repo.get!(CacheEntry, entry.id)
      end
    end

    test "keeps the target it was fetched for" do
      reference = reference!()
      entry = entry!(reference, %{body: "x", fragment: "Intro"})

      assert %CacheEntry{uri: uri, fragment: "Intro"} = Repo.get!(CacheEntry, entry.id)
      assert uri == reference.uri
    end

    test "refuses an entry holding both a body and a path, or neither" do
      reference = reference!()

      for content <- [%{body: "x", path: "1.png"}, %{}] do
        assert {:error, changeset} = insert(reference, content)

        assert %{body: ["holds a body or a path, never both and never neither"]} =
                 errors_on(changeset)
      end
    end

    test "refuses a second entry for one reference" do
      reference = reference!()
      entry!(reference, %{body: "one"})

      assert {:error, changeset} = insert(reference, %{body: "two"})
      assert %{reference_id: ["has already been taken"]} = errors_on(changeset)
    end

    @tag doc: """
         The database rule that makes removing a reference remove its cache
         entry. A failure means the migration lost its `on_delete`, and a
         removed reference leaves a row no read can reach.
         """
    test "goes with its reference" do
      reference = reference!()
      entry!(reference, %{path: "#{reference.id}.png"})

      assert {:ok, _deleted} = References.delete_reference(reference)
      assert Repo.aggregate(CacheEntry, :count) == 0
    end
  end

  defp reference! do
    {:ok, reference} =
      References.create_reference(%{
        title: "A page",
        uri: "https://example.test/#{System.unique_integer([:positive])}"
      })

    reference
  end

  defp insert(reference, content) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    %CacheEntry{}
    |> CacheEntry.changeset(
      Map.merge(
        %{
          reference_id: reference.id,
          uri: reference.uri,
          script: "webpage",
          format: "text/markdown",
          size_bytes: 7,
          fetched_at: now,
          checked_at: now
        },
        content
      )
    )
    |> Repo.insert()
  end

  defp entry!(reference, content) do
    {:ok, entry} = insert(reference, content)
    entry
  end
end
