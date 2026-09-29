defmodule YmerNode.References.Cache.WindowTest do
  use ExUnit.Case, async: true

  alias YmerNode.References.Cache.Window

  doctest Window

  @text "one\ntwo\nthree\nfour\n"

  describe "take/2" do
    test "answers the whole text when it fits, with nothing after it" do
      assert %{text: @text, offset: 1, lines: 4, total_lines: 4, next: nil} = Window.take(@text)
    end

    test "starts at a line and takes at most limit lines, pointing at the next" do
      assert %{text: "two\nthree\n", offset: 2, lines: 2, next: %{offset: 4}} =
               Window.take(@text, offset: 2, limit: 2)
    end

    test "counts a last line with no newline, and answers text with none as it is" do
      assert %{text: "a\nb", total_lines: 2, next: nil} = Window.take("a\nb")
    end

    test "stops before a line that would pass the budget, pointing at it" do
      assert %{text: "one\ntwo\n", lines: 2, next: %{offset: 3}} =
               Window.take(@text, budget: 10)
    end

    @tag doc: """
         A single line longer than the budget — a whole page stored as one line
         — is cut rather than skipped or answered whole, and the answer says
         where on that line to go on. A failure means such a page is either
         unreadable or answered at a size the client parks out of reach.
         """
    test "cuts a line longer than the budget and says where on it to go on" do
      line = String.duplicate("x", 25) <> "\n"

      assert %{text: first, lines: 1, next: %{offset: 1, column: 11}} =
               Window.take(line, budget: 10)

      assert first == String.duplicate("x", 10)

      assert %{text: second, next: %{offset: 1, column: 21}} =
               Window.take(line, column: 11, budget: 10)

      assert second == String.duplicate("x", 10)
      assert %{text: "xxxxx\n", next: nil} = Window.take(line, column: 21, budget: 10)
    end

    test "never cuts inside a character, and counts the column in characters" do
      line = String.duplicate("å", 8) <> "\n"

      assert %{text: "ååååå", next: %{offset: 1, column: 6}} = Window.take(line, budget: 11)
      assert %{text: "ååå\n", next: nil} = Window.take(line, column: 6, budget: 11)
    end

    test "answers an empty window past the last line" do
      assert %{text: "", lines: 0, total_lines: 4, next: nil} = Window.take(@text, offset: 9)
    end

    test "answers an empty text as no lines at all" do
      assert %{text: "", lines: 0, total_lines: 0, next: nil} = Window.take("")
    end

    test "keeps to the default budget with no limit given" do
      line = String.duplicate("y", 999) <> "\n"
      text = String.duplicate(line, 30)

      assert %{lines: 24, next: %{offset: 25}} = Window.take(text)
      assert Window.budget() == 24_000
    end
  end
end
