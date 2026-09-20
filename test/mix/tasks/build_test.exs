defmodule Mix.Tasks.YmerNode.BuildTest do
  @moduledoc """
  Covers the task's pure helpers and its refusal of arguments. Nothing here
  shells out, so the file needs no Docker daemon, no `git` and no network — the
  behaviour that does shell out is proved by running the task itself.

  The live-output cases each open their own `StringIO` and read it back by
  closing it — except the newline-free case, which reads the device
  mid-stream, since only a read before `:done` tells live delivery from line
  buffering. `Mix.Tasks.YmerNode.Build.LiveOutput` says why the device is a
  field.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.YmerNode.Build

  doctest Build

  describe "run/1" do
    @tag doc: """
         Pins the option-less contract: a flag arrives as an argument list, and
         the task has to say it takes none rather than quietly building
         something the caller did not ask for. A failure means an argument-
         accepting clause was added or the clauses were reordered — restore the
         refusal rather than relaxing the assertion.
         """
    test "refuses arguments instead of ignoring them" do
      assert_raise Mix.Error, ~r/takes no arguments/, fn ->
        Build.run(["--arch", "arm64"])
      end
    end
  end

  describe "revision/2" do
    test "no sha means no revision, whatever the tree state" do
      assert Build.revision(nil, :clean) == nil
      assert Build.revision(nil, :unknown) == nil
    end
  end

  describe "image_tags/2" do
    test "the revision tag comes last, so the two stable tags read first" do
      assert List.last(Build.image_tags("3.4.5", "b2a7152")) == "ymer-node:b2a7152"
    end
  end

  describe "build_argv/2" do
    @tag doc: """
         Pins that a revisionless build carries neither the build argument
         nor the label. A failure means an absent revision is reaching
         Docker as a value: the image would claim an empty OCI revision
         label, and the wire version would end in a bare separator.
         """
    test "no revision means no build argument and no label" do
      argv = Build.build_argv(["ymer-node:3.4.5"], nil)

      refute "--build-arg" in argv
      refute "--label" in argv
    end

    test "a revision rides as both a build argument and the OCI label" do
      argv = Build.build_argv(["ymer-node:3.4.5"], "b2a7152")

      assert "YMER_NODE_REVISION=b2a7152" in argv
      assert "org.opencontainers.image.revision=b2a7152" in argv
    end

    test "the build context stays the last argument" do
      assert List.last(Build.build_argv(["ymer-node:3.4.5"], "b2a7152")) == "."
    end
  end

  describe "live_output/1" do
    @tag doc: """
         Guards the regression where a chunk boundary landing inside a
         multi-byte codepoint raised `ArgumentError` mid-build and lost the
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
      {accumulator, collector} = Collectable.into(Build.live_output(device))

      accumulator = collector.(accumulator, {:cont, "Downloading 90%\r"})

      assert StringIO.contents(device) == {"", "Downloading 90%\r"}

      collector.(accumulator, :done)

      assert {:ok, {"", "Downloading 90%\r"}} = StringIO.close(device)
    end

    test "collecting returns the live output itself" do
      {:ok, device} = StringIO.open("")
      live_output = Build.live_output(device)

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
        Enum.into(producer, Build.live_output(device))
      end

      assert {:ok, {"", "started\n"}} = StringIO.close(device)
    end
  end

  defp collect(chunks) do
    {:ok, device} = StringIO.open("")
    _ = Enum.into(chunks, Build.live_output(device))
    {:ok, {"", contents}} = StringIO.close(device)

    contents
  end
end
