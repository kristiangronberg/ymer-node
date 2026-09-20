defmodule YmerNode.Mcp.Tools.Notebook.ErrorsTest do
  @moduledoc """
  Pure message formatting — no repo, no filesystem, hence `async: true`.
  """
  use ExUnit.Case, async: true

  alias YmerNode.Mcp.Tools.Notebook.Errors

  @restored "2026-08-29-09-00-00"
  @safety "2026-08-30-12-00-00"

  describe "message/2 for a notebook that cannot take a call, or a restore that went wrong" do
    @tag doc: """
         These strings are the whole of what a caller learns when a notebook
         answers instead of running — the atoms never leave the node. Each names
         its one next action, and none offers a retry it cannot honour: a wait
         cannot fix a store the node will not open, a second run of a statement
         that may already have committed is not safe, and a backup that is not a
         database will not become one. Nor does any claim more than the node can
         know: the refusal of a backup names this attempt, because a full or
         read-only disk refuses at the same statement as a file that is not a
         database, and the driver gives the node no code to tell them apart. A
         failure means the wording no longer carries the id the caller needs, no
         longer names the one action that helps, or claims a permanence the node
         cannot see.
         """
    test "each answer names its one next action and the ids it depends on" do
      down = Errors.format(:notebook_down, %{})
      assert down =~ "restart the Ymer Node app"
      refute String.downcase(down) =~ "try again"

      not_serving = Errors.format(:notebook_not_serving, %{})
      assert not_serving =~ "cannot open"
      assert not_serving =~ "restart the Ymer Node app"
      refute String.downcase(not_serving) =~ "try again"

      restarted = Errors.format(:notebook_restarted, %{})
      assert restarted =~ "unknown"
      refute String.downcase(restarted) =~ "try again"

      restored =
        Errors.format(
          {:restored_notebook_down, %{restored: @restored, safety_backup: @safety}},
          %{}
        )

      assert restored =~ @restored
      assert restored =~ @safety
      assert restored =~ "Do not retry"
      assert restored =~ "restart the Ymer Node app"

      restored_not_serving =
        Errors.format(
          {:restored_notebook_not_serving, %{restored: @restored, safety_backup: @safety}},
          %{}
        )

      assert restored_not_serving =~ @restored
      assert restored_not_serving =~ @safety
      assert restored_not_serving =~ "Do not retry"

      unreadable = Errors.format({:backup_unreadable, %{safety_backup: @safety}}, %{})
      assert unreadable =~ @safety
      assert unreadable =~ "nothing was overwritten"
      assert unreadable =~ "different backup"
      refute String.downcase(unreadable) =~ "try again"
      refute String.downcase(unreadable) =~ "however many times"

      incomplete = Errors.format({:restore_incomplete, %{safety_backup: @safety}}, %{})
      assert incomplete =~ @safety

      not_started = Errors.format({:restore_not_started, %{safety_backup: @safety}}, %{})
      assert not_started =~ @safety
      assert not_started =~ "retry"
    end

    @tag doc: """
         The clauses have to be reached, not the catch-all: `message/2`'s last two
         clauses `inspect/1` an unmatched reason into the caller's context, which
         is leak-free but useless — and it still looks like a message, so nothing
         downstream would notice. A failure here means a clause was dropped or its
         detail map's keys were renamed on one side only.
         """
    test "none of them falls through to the inspect catch-all" do
      reasons = [
        :notebook_down,
        :notebook_not_serving,
        :notebook_restarted,
        {:restored_notebook_down, %{restored: @restored, safety_backup: @safety}},
        {:restored_notebook_not_serving, %{restored: @restored, safety_backup: @safety}},
        {:backup_unreadable, %{safety_backup: @safety}},
        {:restore_incomplete, %{safety_backup: @safety}},
        {:restore_not_started, %{safety_backup: @safety}}
      ]

      for reason <- reasons do
        message = Errors.format(reason, %{action_verb: "restore the notebook"})
        refute message =~ "Failed to restore the notebook:"
        refute message =~ "%{"
      end
    end
  end

  describe "message/2 for a parameter the boundary refused" do
    @tag doc: """
         The refusal has to be self-correcting: the caller learns the key, the type
         it wanted and what actually arrived, and needs nothing else to fix the
         call. A failure means the clause was dropped and the reason now falls
         through to the `inspect/1` catch-all, which names no key — or that the
         echoed value stopped being bounded, which turns a large array or a wide
         object in the caller's own call into a dump in the answer. An integer,
         bare or nested, is bounded by magnitude before it is rendered, because
         rendering is where its cost sits; every other shape is sliced after
         rendering and the cut is marked, so a shortened echo never reads as the
         value the caller sent. The
         two literals below pin `Errors`' own ceilings — move them together with
         the module's attributes, never to make a red go away.
         """
    test "names the key, the expected type and the value that arrived" do
      message = refusal(42, %{action_verb: "execute SQL"})

      assert message =~ "sql must be a string"
      assert message =~ "got 42"
      refute message =~ "Failed to execute SQL:"

      long = refusal(Enum.to_list(1..50))

      assert long =~ "[1, 2, 3, 4, 5, ...]"
      refute long =~ "49"

      # One past `@echo_integer_ceiling`, which is 10 ** 40.
      huge = refusal(10 ** 41)

      assert huge =~ "got a number too large to echo"
      refute huge =~ "100"

      # The same ceiling reaches an integer nested inside an array or an object —
      # the walk replaces it before anything renders — and it stops where the
      # inspect limit does, so a wide container costs its first entries only.
      assert refusal([10 ** 41]) =~ ~s(got ["a number too large to echo"])
      assert refusal(%{"a" => [%{"b" => 10 ** 41}]}) =~ ~s(got %{"a" => [%{"b" => "a number)
      refute refusal(%{"a" => 10 ** 41, "b" => 2}) =~ "100"

      # Five 100-character strings render well past `@echo_characters` (200) under
      # every bound `show/1` applies, so the echo must come back cut to exactly
      # that length plus the marker — an equality, so a slice that stopped cutting
      # cannot pass on a render that merely happened to be short. The frame is
      # measured off the mechanism rather than retyped: an empty string echoes as
      # the two characters `inspect/1` gives it.
      wide = refusal(Map.new(?a..?e, &{<<&1>>, String.duplicate("x", 100)}))
      frame = String.length(refusal("")) - String.length(inspect(""))

      assert String.length(wide) == frame + 200 + String.length("...")
      # The marker's three dots, then the sentence's own full stop.
      assert String.ends_with?(wide, ".... Send sql as a JSON string.")
    end
  end

  defp refusal(got, ctx \\ %{}) do
    Errors.format({:wrong_type, %{key: "sql", expected: "a string", got: got}}, ctx)
  end
end
