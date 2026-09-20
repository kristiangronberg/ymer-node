defmodule YmerNode.Mcp.Tools.HelpersTest do
  use ExUnit.Case, async: true

  alias YmerNode.Mcp.Tools.Helpers
  alias YmerNode.References.Reference

  doctest YmerNode.Mcp.Tools.Helpers

  describe "maybe_put_if_present/4" do
    test "copies a present key under the attribute name and skips an absent one" do
      assert Helpers.maybe_put_if_present(%{}, %{"title" => "T"}, "title", :title) ==
               %{title: "T"}

      assert Helpers.maybe_put_if_present(%{}, %{}, "title", :title) == %{}
    end

    @tag doc: """
         Presence, not truthiness. An explicit JSON null must reach the changeset
         so that clearing a field by passing null keeps working. A failure here
         means someone "fixed" the boundary by filtering nils, and every clear
         became a silent no-op — the kind of bug a caller reports as "it ignored
         me" long after the change.
         """
    test "an explicit nil is present and travels through" do
      params = %{"description" => nil}
      attrs = Helpers.maybe_put_if_present(%{}, params, "description", :description)

      assert attrs == %{description: nil}
    end
  end

  describe "compact/1" do
    test "drops nils and empty lists, keeps every other falsy-looking value" do
      assert Helpers.compact(%{a: nil, b: [], c: "", d: 0, e: false, f: %{}}) ==
               %{c: "", d: 0, e: false, f: %{}}
    end
  end

  describe "format_changeset_errors/1" do
    @tag doc: """
         The interpolation is what makes the message actionable: a raw
         `"should be at least %{count} character(s)"` reaching a caller tells it
         nothing about which number to clear. A failure means `traverse_errors`
         stopped being handed the interpolating function.
         """
    test "renders field errors with their interpolations applied" do
      changeset = Reference.changeset(%Reference{}, %{title: "E", uri: "https://x"})

      message = Helpers.format_changeset_errors(changeset)

      assert message =~ "Validation failed:"
      assert message =~ "- title: should be at least 2 character(s)"
      refute message =~ "%{count}"
    end

    @tag doc: """
         The cast path, which the length case above cannot reach: a wrong-typed
         field puts the field's type in the error opts — `{:array, :string}` for
         tags — and that tuple has no `String.Chars` implementation. A failure
         that raises `Protocol.UndefinedError` means the renderer went back to
         folding every opt through `to_string/1`, and `add`/`update` with a
         non-array `tags` crash the call again instead of answering.
         """
    test "renders a cast error whose opts carry a type tuple" do
      changeset =
        Reference.changeset(%Reference{}, %{title: "Fine", uri: "https://x", tags: "elixir"})

      message = Helpers.format_changeset_errors(changeset)

      assert message =~ "- tags: is invalid"
    end

    @tag doc: """
         The renderer is total over hand-written messages too: a placeholder the
         opts do not name stays visible as written, and a named value with no
         `String.Chars` implementation renders through `inspect/1`. A failure on
         the first assertion means a lost opt started rendering as a bare word
         (`count` for `%{count}`), which reads like a real message; a raise on
         the second means an `add_error/4` carrying a structured opt crashes
         the call.
         """
    test "leaves an unnamed placeholder visible and inspects a non-string value" do
      changeset =
        %Reference{}
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.add_error(:title, "needs at least %{count}", validation: :length)
        |> Ecto.Changeset.add_error(:tags, "bad %{type}", type: {:array, :string})

      message = Helpers.format_changeset_errors(changeset)

      assert message =~ "- title: needs at least %{count}"
      assert message =~ "- tags: bad {:array, :string}"
    end
  end
end
