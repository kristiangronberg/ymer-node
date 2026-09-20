defmodule YmerNode.Mcp.Tools.References.ActionsTest do
  @moduledoc """
  Exercises the six actions end-to-end through the repo, so `YmerNode.DataCase`
  and no async flag.

  Only built-in sources appear here, because `Sources.declarations/0` answers the
  empty list until script rows exist. The declared-source half — a script's name
  as the source, and the `scripts run` recipe — is pinned in
  `YmerNode.References.SourcesTest` and `YmerNode.Mcp.Tools.References.FormatTest`,
  both of which pass declarations explicitly.
  """
  use YmerNode.DataCase

  alias YmerNode.Mcp.Tools.References.{Actions, Errors}
  alias YmerNode.References

  defp reference!(attrs) do
    defaults = %{
      title: "untitled reference",
      uri: "https://example.com/#{System.unique_integer([:positive])}"
    }

    {:ok, reference} = References.create_reference(Map.merge(defaults, attrs))
    reference
  end

  describe "add" do
    test "creates a reference and returns it with its derived source" do
      assert {:ok, response, %{id: id}} =
               Actions.run(:add, %{
                 "title" => "Elixir getting started",
                 "uri" => "https://elixir-lang.org/getting-started/introduction.html",
                 "tags" => ["elixir"]
               })

      assert response.message == "Reference ##{id} added"
      assert response.reference.source == "web"
      assert response.reference.tags == ["elixir"]
      refute Map.has_key?(response.reference, :recipe)
    end

    @tag doc: """
         The duplicate add as a wire response: a SUCCESS pointing at the existing
         reference with an update-or-tag steer. An LLM reads an error as "retry
         differently", which forks the registry through a mutated uri. A failure
         means the duplicate became an error again — check the registry for
         near-duplicate rows before assuming this test is merely stale.
         """
    test "an exact duplicate returns the existing reference with a steer, not an error" do
      existing = reference!(%{uri: "https://example.com/page", fragment: "Setup"})

      assert {:ok, response, %{id: id, duplicate: true}} =
               Actions.run(:add, %{
                 "title" => "Renamed",
                 "uri" => "https://example.com/page",
                 "fragment" => "Setup"
               })

      assert id == existing.id
      assert response.message =~ "already exists as ##{existing.id}"
      assert response.message =~ "update or tag"
      assert [_only_one] = References.list_references()
    end

    test "changeset errors surface through the error path" do
      assert {:error, {%Ecto.Changeset{}, _ctx}} =
               Actions.run(:add, %{"title" => "E", "uri" => "https://x"})
    end

    @tag doc: """
         The dispatch layer checks a param's presence and never its type, so a
         string where the schema declares an array reaches the changeset as
         written. A raise here means the error renderer stopped being total
         over cast errors, and a wrong-typed write field crashes the call
         instead of answering with the field's name.
         """
    test "a wrong-typed tags value answers a changeset error rather than raising" do
      assert {:error, {%Ecto.Changeset{} = changeset, _ctx}} =
               Actions.run(:add, %{"title" => "Typed", "uri" => "https://x", "tags" => "elixir"})

      assert Errors.format(changeset) =~ "- tags: is invalid"
    end
  end

  describe "find" do
    test "requires at least one criterion" do
      assert {:error, {:empty_find, _ctx}} = Actions.run(:find, %{})
    end

    test "filter mode: tags and source narrow, and the mode is reported" do
      local = reference!(%{title: "local note", uri: "/Users/k/notes.md", tags: ["kept"]})
      _web = reference!(%{title: "web thing", tags: ["kept"]})

      assert {:ok, response, %{}} =
               Actions.run(:find, %{"tags" => ["kept"], "source" => "file"})

      assert response.mode == "filter"
      assert response.count == 1
      assert [%{id: id, source: "file"}] = response.results
      assert id == local.id
    end

    test "keyword mode: the query ranks and scores" do
      hit = reference!(%{title: "release checklist"})
      _miss = reference!(%{title: "unrelated"})

      assert {:ok, response, %{}} = Actions.run(:find, %{"query" => "release"})
      assert response.mode == "keyword"
      assert [%{id: id, score: 1}] = response.results
      assert id == hit.id
    end

    @tag doc: """
         The dispatch layer checks that a parameter is present and never what it
         holds, so each of these values reaches the boundary as written. Each
         failure is a distinct atom so the caller is told which parameter to fix;
         a failure here means two faults collapsed into one message.
         """
    test "value-blind params are rejected with distinct errors" do
      assert {:error, {:empty_query, _}} = Actions.run(:find, %{"query" => "   "})
      assert {:error, {:invalid_tags, _}} = Actions.run(:find, %{"tags" => [1, 2]})
      assert {:error, {:invalid_source, _}} = Actions.run(:find, %{"source" => "no-such-script"})
      assert {:error, {:invalid_limit, _}} = Actions.run(:find, %{"query" => "x", "limit" => 0})
    end
  end

  describe "get" do
    test "returns the formatted reference; empty tags are compacted away" do
      reference = reference!(%{title: "Named", fragment: "Section"})

      assert {:ok, %{reference: formatted}, %{}} = Actions.run(:get, %{"id" => reference.id})
      assert formatted.id == reference.id
      assert formatted.fragment == "Section"
      refute Map.has_key?(formatted, :tags)
    end

    test "missing and malformed ids error distinctly" do
      assert {:error, {:not_found, _}} = Actions.run(:get, %{"id" => 999_999})
      assert {:error, {:invalid_id, _}} = Actions.run(:get, %{"id" => "banana"})
    end
  end

  describe "update" do
    test "changes only the provided fields; tags replace rather than merge" do
      reference = reference!(%{title: "before", tags: ["a"]})

      assert {:ok, response, %{id: _id}} =
               Actions.run(:update, %{"id" => reference.id, "tags" => ["b", "c"]})

      assert response.reference.title == "before"
      assert response.reference.tags == ["b", "c"]
    end

    @tag doc: """
         An explicit JSON null passes `maybe_put_if_present/4` — which checks key
         PRESENCE, not nil — and reaches the changeset BY DESIGN, because
         clearing a field with null has to keep working. Do NOT "fix" this by
         filtering nils at the boundary. The changeset's nil-safe trim is what
         turns a null title into "can't be blank"; without it the call crashes
         with `FunctionClauseError` inside `String.trim/1` instead.
         """
    test "a JSON-null title is a changeset error, not a crash" do
      reference = reference!(%{title: "before"})

      assert {:error, {%Ecto.Changeset{} = changeset, _ctx}} =
               Actions.run(:update, %{"id" => reference.id, "title" => nil})

      assert %{title: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "remove" do
    test "hard-deletes" do
      reference = reference!(%{})

      assert {:ok, %{message: message}, %{}} = Actions.run(:remove, %{"id" => reference.id})
      assert message == "Reference ##{reference.id} removed"
      assert {:error, :not_found} = References.get_reference(reference.id)
    end
  end

  describe "list" do
    test "returns everything in title order" do
      reference!(%{title: "banana"})
      reference!(%{title: "Apple"})

      assert {:ok, %{count: 2, references: [first, second]}, %{}} = Actions.run(:list, %{})
      assert first.title == "Apple"
      assert second.title == "banana"
    end
  end
end
