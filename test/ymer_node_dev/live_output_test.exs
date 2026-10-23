defmodule YmerNodeDev.LiveOutputTest do
  @moduledoc """
  Each case opens its own `StringIO` and reads it back by closing it — except
  the newline-free case, which reads the device mid-stream, since only a read
  before `:done` tells live delivery from line buffering.
  `YmerNodeDev.LiveOutput` says why the device is a field.
  """
  use ExUnit.Case, async: true

  alias YmerNodeDev.LiveOutput

  describe "Collectable.into/1" do
    @tag doc: """
         Guards the regression where a chunk boundary landing inside a
         multi-byte codepoint raised `ArgumentError` mid-run and lost the
         rest of the log. A failure means the truncated sequence is no longer
         held back for the next chunk — read the `:incomplete` branch before
         touching the assertion.
         """
    test "a codepoint split across two chunks is written once, complete" do
      assert collect(["line one\n" <> <<0xE2, 0x94>>, <<0x82>> <> " rest of line\n"]) ==
               "line one\n│ rest of line\n"
    end

    test "a byte that can begin no valid sequence is written as the replacement" do
      assert collect(["good\n", "tail " <> <<0xFF, 0xFE>> <> "\n", "more\n"]) ==
               "good\ntail ��\nmore\n"
    end

    test "a truncated sequence followed by a valid byte costs one replacement per byte" do
      assert collect([<<0xE2, 0x94, 0x41>>]) == "��A"
    end

    test "an incomplete tail at the end of the output becomes replacements" do
      assert collect(["ok " <> <<0xE2, 0x94>>]) == "ok ��"
    end

    test "valid UTF-8 comes out byte-identical, wherever the chunks fall" do
      log = String.duplicate("│ compiling ✓\n", 200)

      chunks =
        log
        |> :binary.bin_to_list()
        |> Enum.chunk_every(7)
        |> Enum.map(&:binary.list_to_bin/1)

      assert collect(chunks) == log
    end

    @tag doc: """
         Pins that nothing waits for a newline. A failure signals that the
         collectable started buffering by line — read what reaches the device
         per chunk, not what is there once the output has ended.
         """
    test "a chunk carrying no newline reaches the device as it arrives" do
      {:ok, device} = StringIO.open("")
      {accumulator, collector} = Collectable.into(%LiveOutput{device: device})

      accumulator = collector.(accumulator, {:cont, "Downloading 90%\r"})

      assert StringIO.contents(device) == {"", "Downloading 90%\r"}

      collector.(accumulator, :done)

      assert {:ok, {"", "Downloading 90%\r"}} = StringIO.close(device)
    end

    test "collecting returns the live output itself" do
      {:ok, device} = StringIO.open("")
      live_output = %LiveOutput{device: device}

      assert Enum.into(["ok\n"], live_output) == live_output
      assert {:ok, {"", "ok\n"}} = StringIO.close(device)
    end

    @tag doc: """
         Pins that halting is not a raise. `System.cmd/3` calls the collector
         with `:halt` from inside its own `catch`, before re-raising what the
         producer threw, so a clause missing there replaces the real failure
         with a `FunctionClauseError` naming this module — the diagnostic the
         operator needed, gone. A failure means the `:halt` clause was dropped
         or narrowed to a shape the initial accumulator no longer matches.
         """
    test "a producer that stops mid-collection surfaces its own error" do
      producer =
        Stream.map([1, 2], fn
          1 -> "started\n"
          2 -> raise "the producer stopped"
        end)

      {:ok, device} = StringIO.open("")

      assert_raise RuntimeError, "the producer stopped", fn ->
        Enum.into(producer, %LiveOutput{device: device})
      end

      assert {:ok, {"", "started\n"}} = StringIO.close(device)
    end
  end

  defp collect(chunks) do
    {:ok, device} = StringIO.open("")
    _ = Enum.into(chunks, %LiveOutput{device: device})
    {:ok, {"", contents}} = StringIO.close(device)

    contents
  end
end
