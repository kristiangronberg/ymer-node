defmodule YmerNode.Mcp.Tools.Notebook.FormatTest do
  @moduledoc """
  Pure shaping tests for the three backup responses. These are runtime map
  constructions the set-theoretic type checker cannot validate — a key typo
  compiles clean — and no dispatch test reaches the restore success shape, which
  needs a real repo restart. The note is the caller's only warning that the undo
  anchor is itself perishable, so pin the exact shapes here.
  """
  use ExUnit.Case, async: true

  alias YmerNode.Mcp.Tools.Notebook.Format

  @entry %{id: "2026-08-30-12-00-00", created_at: "2026-08-30T12:00:00Z", size_bytes: 4096}

  test "backup/1 passes the entry through unchanged" do
    assert Format.backup(@entry) == @entry
  end

  test "backups/1 wraps the list with a count" do
    assert Format.backups([@entry]) == %{count: 1, backups: [@entry]}
    assert Format.backups([]) == %{count: 0, backups: []}
  end

  test "restore/1 keeps both ids and names the safety backup in the note" do
    shaped =
      Format.restore(%{restored: "2026-06-01-00-00-00", safety_backup: "2026-08-30-12-00-00"})

    assert shaped.restored == "2026-06-01-00-00-00"
    assert shaped.safety_backup == "2026-08-30-12-00-00"
    assert shaped.note =~ "2026-08-30-12-00-00"
    assert shaped.note =~ "retention limit"
  end

  @tag doc: """
       The success path's half of the opacity boundary: the note is the one
       caller-facing string assembled by interpolating into free-form prose, and
       the forced-failure cases in the dispatch tests pin only the error half.
       A failure means a path fragment reached the note's text — restore the
       opacity rather than relaxing the forbidden list.
       """
  test "restore/1's note names no filesystem path" do
    shaped =
      Format.restore(%{restored: "2026-06-01-00-00-00", safety_backup: "2026-08-30-12-00-00"})

    note = String.downcase(shaped.note)

    for forbidden <- ["path", "file", "/data", ".db", "notebook-", "directory"] do
      refute note =~ forbidden, "leaked #{inspect(forbidden)} to the caller: #{shaped.note}"
    end
  end
end
