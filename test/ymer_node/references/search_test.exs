defmodule YmerNode.References.SearchTest do
  use YmerNode.DataCase

  alias YmerNode.References
  alias YmerNode.References.{Reference, Search}

  doctest YmerNode.References.Search

  defp reference!(attrs) do
    defaults = %{
      title: "untitled reference",
      uri: "https://example.com/#{System.unique_integer([:positive])}"
    }

    {:ok, reference} = References.create_reference(Map.merge(defaults, attrs))
    reference
  end

  describe "run/1 — filter mode (no query)" do
    test "tag-AND plus source, mode :filter, nil scores" do
      hit = reference!(%{title: "local note", uri: "/Users/k/notes.md", tags: ["kept"]})
      _wrong_source = reference!(%{title: "web thing", tags: ["kept"]})

      assert %{mode: :filter, results: [%{reference: %Reference{id: id}, score: nil}]} =
               Search.run(tags: ["kept"], source: "file")

      assert id == hit.id
    end

    test "no criteria at all returns everything — the caller gates emptiness" do
      reference!(%{title: "solo"})
      assert %{mode: :filter, results: [_one]} = Search.run([])
    end
  end

  describe "run/1 — keyword mode" do
    @tag doc: """
         The keyword projection is every text field, so a term carried only by a
         uri or a fragment matches a reference whose title never mentions it. A
         failure means the projection narrowed to prose, and identifiers stopped
         being findable — which is most of what a registry is searched by.
         """
    test "matches identifiers in the uri and text in the fragment" do
      uri_hit = reference!(%{title: "release board", uri: "https://example.com/browse/ABC-1234"})
      fragment_hit = reference!(%{title: "wiki page", fragment: "Release notes section"})
      _miss = reference!(%{title: "unrelated"})

      assert %{mode: :keyword, results: [%{reference: %Reference{id: id}, score: 1}]} =
               Search.run(query: "ABC-1234")

      assert id == uri_hit.id

      assert %{mode: :keyword, results: [%{reference: %Reference{id: id}, score: 1}]} =
               Search.run(query: "notes")

      assert id == fragment_hit.id
    end

    test "score is distinct terms matched, higher score first" do
      one = reference!(%{title: "corporate onboarding"})
      two = reference!(%{title: "corporate actions onboarding"})

      assert %{mode: :keyword, results: [first, second]} = Search.run(query: "corporate actions")

      assert first.reference.id == two.id
      assert first.score == 2
      assert second.reference.id == one.id
      assert second.score == 1
    end

    @tag doc: """
         timestamps are second-precision, so both legs pin updated_at
         explicitly. The same-second leg covers the id-descending fallback, and
         the backdated leg covers updated_at outranking id. A failure means the
         tie-break key changed: check `sort_ranked/1`'s tuple before touching
         either leg.
         """
    test "equal-score ties break newest-updated first, then id desc" do
      first_created = reference!(%{title: "emission handbook"})
      later_created = reference!(%{title: "emission checklist"})
      past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

      Repo.update_all(
        from(r in Reference, where: r.id in ^[first_created.id, later_created.id]),
        set: [updated_at: past]
      )

      assert %{mode: :keyword, results: results} = Search.run(query: "emission")
      assert Enum.map(results, & &1.reference.id) == [later_created.id, first_created.id]
      assert Enum.map(results, & &1.score) == [1, 1]

      Repo.update_all(from(r in Reference, where: r.id == ^later_created.id),
        set: [updated_at: DateTime.add(past, -60, :second)]
      )

      assert %{mode: :keyword, results: results} = Search.run(query: "emission")
      assert Enum.map(results, & &1.reference.id) == [first_created.id, later_created.id]
    end

    test "filters narrow before ranking" do
      tagged = reference!(%{title: "emission handbook", tags: ["kept"]})
      _untagged = reference!(%{title: "emission scratchpad"})

      assert %{mode: :keyword, results: [%{reference: %Reference{id: id}}]} =
               Search.run(query: "emission", tags: ["kept"])

      assert id == tagged.id
    end

    test "a query with no usable terms returns zero hits, not an error" do
      reference!(%{title: "anything"})
      assert %{mode: :keyword, results: []} = Search.run(query: "a")
    end

    test "limit caps ranked results" do
      reference!(%{title: "emission one"})
      reference!(%{title: "emission two"})

      assert %{mode: :keyword, results: [_only]} = Search.run(query: "emission", limit: 1)
    end

    @tag doc: """
         There are two modes and not three. A failure here means a third mode
         reached the response — the wire contract says `mode` names the ranking
         that ran, and a caller that reads "keyword" has been told its query was
         scored by term matching.
         """
    test "a query always reports keyword mode" do
      reference!(%{title: "anything"})

      assert %{mode: :keyword} = Search.run(query: "anything")
      assert %{mode: :keyword} = Search.run(query: "no-such-term-anywhere")
    end
  end
end
