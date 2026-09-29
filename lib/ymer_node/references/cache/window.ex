defmodule YmerNode.References.Cache.Window do
  @moduledoc """
  One window onto a text cache entry: the lines from `offset`, at most `limit`
  of them, and never more bytes than the budget — whichever comes first.

  Lines, because they are how a reader of text finds its way, and the byte
  budget because a line can be anything: a page stored as a single line of
  190 000 bytes is real, and a window measured in lines alone would answer it
  whole. The budget is 24 000 bytes of text, measured before the answer is
  encoded — kept under the size at which a client stops showing a tool's
  answer inline and parks it in a file.

  A line longer than what is left of the budget is never skipped. When it is
  the window's first line it is cut at the budget, on a character boundary,
  and `next` names the same line and the character to go on from (`column`,
  counted in code points from 1); otherwise the window stops before it, and
  `next` names it. A window that reaches the end answers `next: nil`.

  Pure over its arguments: `YmerNode.References.Cache` hands it the text and
  the reader's position, and the answer is what it serves.
  """

  @budget 24_000

  @doc "The byte budget one window keeps to."
  def budget, do: @budget

  @doc """
  The window of `text` the options name — `:offset` (the first line, from 1),
  `:limit` (a line count; as many as fit when absent), `:column` (the
  character of the first line to start from, from 1) and `:budget` (bytes) —
  answered with the text, where it starts, how many lines it holds, how many
  the whole text has, and where the next window starts.

  ## Examples

      iex> YmerNode.References.Cache.Window.take("a\\nb\\nc\\n", offset: 2, limit: 1)
      %{text: "b\\n", offset: 2, lines: 1, total_lines: 3, next: %{offset: 3}}

      iex> YmerNode.References.Cache.Window.take("abcdef\\n", budget: 4)
      %{text: "abcd", offset: 1, lines: 1, total_lines: 1, next: %{offset: 1, column: 5}}

  """
  def take(text, options \\ []) when is_binary(text) and is_list(options) do
    offset = Keyword.get(options, :offset, 1)
    column = Keyword.get(options, :column, 1)
    budget = Keyword.get(options, :budget, @budget)
    all = lines(text)
    total = length(all)

    window =
      all
      |> Enum.drop(offset - 1)
      |> drop_first(column - 1)
      |> fill(Keyword.get(options, :limit), budget, offset, column)

    Map.merge(%{offset: offset, total_lines: total}, window)
    |> finish(total)
  end

  # Lines keep their newline, so a window's text is the entry's bytes exactly.
  defp lines(""), do: []
  defp lines(text), do: text |> String.split(~r/(?<=\n)/) |> Enum.reject(&(&1 == ""))

  defp drop_first([first | rest], skip) when skip > 0, do: [drop_codepoints(first, skip) | rest]
  defp drop_first(lines, _skip), do: lines

  defp fill([], _limit, _budget, _offset, _column), do: %{text: "", lines: 0, next: nil}

  defp fill([first | _rest], _limit, budget, offset, column) when byte_size(first) > budget do
    cut = cut(first, budget)
    %{text: cut, lines: 1, next: %{offset: offset, column: column + codepoints(cut)}}
  end

  defp fill(lines, limit, budget, offset, _column) do
    taken = take_lines(lines, limit || length(lines), budget, [])
    count = length(taken)
    %{text: IO.iodata_to_binary(taken), lines: count, next: %{offset: offset + count}}
  end

  defp take_lines([line | rest], limit, budget, taken)
       when limit > 0 and byte_size(line) <= budget,
       do: take_lines(rest, limit - 1, budget - byte_size(line), [line | taken])

  defp take_lines(_lines, _limit, _budget, taken), do: Enum.reverse(taken)

  # `next` is dropped once it points past the last line — unless a cut line is
  # to be read on from.
  defp finish(%{next: %{offset: next} = position} = window, total)
       when next > total and not is_map_key(position, :column),
       do: %{window | next: nil}

  defp finish(window, _total), do: window

  defp cut(line, budget), do: trim_partial(binary_part(line, 0, budget))

  defp trim_partial(prefix) do
    if String.valid?(prefix),
      do: prefix,
      else: trim_partial(binary_part(prefix, 0, byte_size(prefix) - 1))
  end

  defp drop_codepoints(text, 0), do: text
  defp drop_codepoints(<<_char::utf8, rest::binary>>, n), do: drop_codepoints(rest, n - 1)
  defp drop_codepoints(<<>>, _n), do: ""

  defp codepoints(text), do: text |> String.to_charlist() |> length()
end
