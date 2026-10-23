if Mix.env() in [:dev, :test] do
  # Remediation(removable: Elixir's `IO.stream/2` no longer raises on a chunk
  # boundary that falls inside a multi-byte codepoint): the stdlib collectable
  # writes each raw port chunk straight to a unicode device, and
  # `Mix.Shell.IO.cmd/2` carries the identical defect, so neither can carry a
  # subprocess whose output is not pure ASCII.
  # plan: 2026-09-05-docker-output-streaming
  defmodule YmerNodeDev.LiveOutput do
    @moduledoc """
    A subprocess's output reaching the terminal as it is produced — faithful
    for valid UTF-8, with anything unreadable shown as `�`, and unable to stop
    the task that runs it, whatever bytes it carries.

    The port hands `System.cmd/3`'s collectable flat 65536-byte chunks, so a
    boundary falls wherever the byte count lands — regularly inside one of the
    box-drawing characters a compiler diagnostic is framed with. The device
    those bytes go to is a unicode one, and stays one when stdout is redirected
    to a file, so half a codepoint reaching it raises instead of printing.
    `IO.stream/2`'s second argument is no lever against that: `:line` and a
    byte count alike shape the read direction only, and the collectable it
    returns writes every chunk it is handed straight to the device whichever
    one is passed — so the line-at-a-time framing that argument suggests was
    never real, and tuning it was never a fix.

    This collectable therefore never presents an incomplete or invalid sequence
    to the device. It holds back a trailing sequence the bytes so far still
    allow to be a codepoint — at most three bytes — and prepends it to the next
    chunk; a sequence a byte has already ruled out has its first byte written
    as `�` and the remainder re-split behind it. Nothing else is read out of
    the bytes: no lines, no escape sequences, no assumption about what the
    subprocess prints. That is what keeps a carriage-return progress redraw on
    screen as it arrives, where a collectable buffering by line shows a fast
    progress line once, at the end.

    What it collects must be iodata: `System.cmd/3` opens its port with
    `:binary`, so that is what it is handed. Chardata is not accepted, and the
    narrowing is silent rather than loud — a codepoint list is read as bytes,
    so codepoints 128–255 come out as `�` and anything larger raises in
    `IO.iodata_to_binary/1`.

    The device is a field rather than a fixed `:stdio` because a `StringIO`
    enforces the same encoding: a test can prove the property against one
    without capturing the run's own output. The Mix tasks that run a
    subprocess pass `%YmerNodeDev.LiveOutput{device: :stdio}` as
    `System.cmd/3`'s `:into`.
    """

    defstruct [:device]

    defimpl Collectable do
      def into(live_output) do
        {{live_output, ""}, &collect/2}
      end

      # `IO.iodata_to_binary/1` also flattens, and the `:error` clause below
      # relies on it: `:unicode.characters_to_binary/3` returns the unreadable
      # rest as a binary only when it was handed one.
      defp collect({live_output, held}, {:cont, data}) do
        {live_output, write(live_output.device, held <> IO.iodata_to_binary(data))}
      end

      defp collect({live_output, held}, :done) do
        replace_held(live_output.device, held)
        live_output
      end

      defp collect(_accumulator, :halt), do: :ok

      defp write(device, data), do: write(device, data, [])

      # The accumulator is what keeps a run of unreadable bytes to one write.
      # Emitting per fragment costs a synchronous round trip to the device for
      # every byte replaced, so a chunk that is mostly not UTF-8 — a build step
      # dumping a binary — would spend tens of thousands of them and read as a
      # stall. `unwind/2` keeps the ordinary all-valid chunk a bare binary — and
      # an empty one the `""` that `emit/2` skips.
      defp write(device, data, accumulator) do
        case :unicode.characters_to_binary(data, :utf8, :utf8) do
          binary when is_binary(binary) ->
            emit(device, unwind(accumulator, binary))
            ""

          {:incomplete, readable, truncated} ->
            emit(device, unwind(accumulator, readable))
            truncated

          {:error, readable, <<_unreadable, rest::binary>>} ->
            write(device, rest, ["�", readable | accumulator])
        end
      end

      defp unwind([], binary), do: binary
      defp unwind(accumulator, binary), do: Enum.reverse([binary | accumulator])

      defp emit(_device, ""), do: :ok
      defp emit(device, iodata), do: IO.write(device, iodata)

      # Nothing can complete a held sequence once the output has ended, so what
      # was held is unreadable by then and takes the same per-byte rule.
      defp replace_held(device, held), do: emit(device, String.duplicate("�", byte_size(held)))
    end
  end
end
