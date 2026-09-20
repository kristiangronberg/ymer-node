defmodule YmerNode.References.ReferenceTest do
  use YmerNode.DataCase

  alias YmerNode.References.Reference

  describe "changeset/2" do
    test "valid with title and uri only; fragment and tags take defaults" do
      changeset =
        Reference.changeset(%Reference{}, %{title: "Elixir docs", uri: "https://elixir-lang.org"})

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :fragment) == ""
      assert Ecto.Changeset.get_field(changeset, :tags) == []
    end

    test "trims title and uri" do
      changeset =
        Reference.changeset(%Reference{}, %{
          title: "  Elixir docs  ",
          uri: " https://elixir-lang.org "
        })

      assert Ecto.Changeset.get_field(changeset, :title) == "Elixir docs"
      assert Ecto.Changeset.get_field(changeset, :uri) == "https://elixir-lang.org"
    end

    test "normalizes a nil or blank fragment to the empty string" do
      for fragment <- [nil, "", "   "] do
        changeset =
          Reference.changeset(%Reference{}, %{
            title: "Elixir docs",
            uri: "https://x",
            fragment: fragment
          })

        assert Ecto.Changeset.get_field(changeset, :fragment) == "",
               "fragment #{inspect(fragment)} should normalize to \"\""
      end
    end

    test "keeps a real fragment, trimmed" do
      changeset =
        Reference.changeset(%Reference{}, %{
          title: "Elixir docs",
          uri: "https://x",
          fragment: " Getting started "
        })

      assert Ecto.Changeset.get_field(changeset, :fragment) == "Getting started"
    end

    test "requires title and uri; title needs at least 2 characters" do
      assert %{title: ["can't be blank"], uri: ["can't be blank"]} =
               errors_on(Reference.changeset(%Reference{}, %{}))

      assert %{title: ["should be at least 2 character(s)"]} =
               errors_on(Reference.changeset(%Reference{}, %{title: "E", uri: "https://x"}))
    end

    @tag doc: """
         The ceiling is enforced by the changeset, not only declared in the
         tool's JSON schema — the dispatch layer checks that a parameter is
         present and never what it holds, so a schema-only maxLength is an
         unenforced claim. A failure means the rule moved back out of the
         changeset and an arbitrarily long title can reach the database again.
         """
    test "title is capped at 255 characters" do
      assert %{title: ["should be at most 255 character(s)"]} =
               errors_on(
                 Reference.changeset(%Reference{}, %{
                   title: String.duplicate("t", 256),
                   uri: "https://x"
                 })
               )

      assert Reference.changeset(%Reference{}, %{
               title: String.duplicate("t", 255),
               uri: "https://x"
             }).valid?
    end

    @tag doc: """
         `update_change/3` applies its function to a recorded nil change, and an
         explicit nil param records one — a JSON null through the tool boundary,
         which `maybe_put_if_present/4` forwards by design. A bare
         `String.trim/1` in the changeset therefore crashes with
         `FunctionClauseError` instead of returning "can't be blank". This pins
         the nil-safe trim at the changeset, which is the trust boundary.
         """
    test "update with a nil or blank title/uri yields blank errors, never a crash" do
      persisted = %Reference{id: 1, title: "Elixir docs", uri: "https://x"}

      assert %{title: ["can't be blank"]} =
               errors_on(Reference.changeset(persisted, %{title: nil}))

      assert %{title: ["can't be blank"], uri: ["can't be blank"]} =
               errors_on(Reference.changeset(persisted, %{"title" => "", "uri" => ""}))
    end
  end

  describe "search_text/1" do
    test "joins title, description, fragment, uri, and tags" do
      reference = %Reference{
        title: "T",
        description: "D",
        fragment: "F",
        uri: "https://u/ABC-1234",
        tags: ["a", "b"]
      }

      assert Reference.search_text(reference) == "T\nD\nF\nhttps://u/ABC-1234\na b"
    end

    test "skips nil and empty fields" do
      reference = %Reference{
        title: "T",
        description: nil,
        fragment: "",
        uri: "https://u",
        tags: []
      }

      assert Reference.search_text(reference) == "T\nhttps://u"
    end
  end
end
