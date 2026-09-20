defmodule YmerNode.Mcp.Tools.Notebook.Errors do
  @moduledoc """
  Translates `YmerNode.Notebook` and `YmerNode.Notebook.Backup` error reasons into
  LLM-readable messages. SQLite errors are surfaced verbatim so the agent can read
  and fix its own SQL; backup failures never are, because their detail carries
  filesystem paths the caller must not see.

  One reason reaches here from neither context:
  `YmerNode.Mcp.Tools.Notebook.Actions` refuses a parameter of the wrong type
  before either of them runs, and its message is the only thing that tells the
  caller which key to fix.
  """

  # Bounds on the value echoed back to the caller. An integer is bounded by
  # magnitude rather than by its rendered length, because rendering is where the
  # cost is, and a container is walked to the entries `inspect/2` will print so
  # the same bound reaches an integer nested inside it; everything else is
  # bounded after rendering.
  @echo_integer_ceiling 10 ** 40
  @echo_terms 5
  @echo_characters 200

  def format(reason, ctx \\ %{}), do: message(reason, ctx)

  def message(%Exqlite.Error{message: m}, _ctx), do: "SQLite error: #{m}"

  def message(:not_read_only, _ctx),
    do:
      "The query action only runs SELECT/WITH/EXPLAIN. For schema/column introspection " <>
        "use the tables/schema actions; use execute only for writes and DDL."

  def message(:blocked_statement, _ctx),
    do:
      "ATTACH/DETACH are not allowed. The notebook is the only database this tool " <>
        "opens, and no statement may reach past it to another file."

  def message(:blocked_vacuum_into, _ctx),
    do:
      "VACUUM INTO is not allowed — it writes a copy of the notebook to an arbitrary " <>
        "file. To save a backup, use the create action. If you sent a bare VACUUM " <>
        "followed by other statements, send it alone — only the first statement runs."

  def message(:table_not_found, _ctx), do: "No such table. Call the tables action to list them."

  def message(:operation_in_progress, _ctx),
    do: "A backup or restore is already running. Wait for it to finish, then try again."

  def message(:backup_not_found, _ctx),
    do: "No backup with that id. Call list to see the saved backups and their ids."

  def message(:invalid_backup_id, _ctx),
    do: "That backup id is not valid. Use an id exactly as returned by list."

  # Path-free failures from the backup boundary. The path-bearing detail is
  # logged server-side; the agent only ever sees these generic strings.
  def message(:backup_failed, _ctx),
    do: "Couldn't save the backup. Try again; if it keeps happening, check the node's logs."

  def message(:restore_failed, _ctx),
    do: "Couldn't complete the restore. Try again; if it keeps happening, check the node's logs."

  def message(:backups_failed, _ctx),
    do: "Couldn't list the backups. Try again; if it keeps happening, check the node's logs."

  # A stopped notebook, and the three ways a restore can end badly. Each names the
  # one action that actually helps — a person restarting the app where the notebook
  # is down, a retry where nothing was overwritten, the safety backup where
  # something was — and none of them offers a retry it cannot honour. The atoms
  # stay inside the node; these strings are the whole answer.
  def message(:notebook_down, _ctx),
    do:
      "The notebook is down: no notebook action except listing backups can succeed " <>
        "until the node is restarted. Ask the user to restart the Ymer Node app."

  def message({:restored_notebook_down, %{restored: restored, safety_backup: safety}}, _ctx),
    do:
      "The restore completed: the notebook now holds backup #{restored}, safely on disk. " <>
        "But the notebook did not come back up afterwards and is down. Do not retry — the " <>
        "restore already happened, and no notebook action except listing backups can " <>
        "succeed right now. Ask the user to restart the Ymer Node app; it will start on " <>
        "the restored data. To undo the restore after that, restore backup #{safety}."

  def message({:restore_not_started, %{safety_backup: safety}}, _ctx),
    do:
      "The restore did not go through and the notebook is unchanged — nothing was " <>
        "overwritten. A backup of the current state was saved as id #{safety} and is listed " <>
        "like any other. You can retry once; if it fails again, the cause is in the node's " <>
        "logs — ask the user to check them, or restore a different backup from list."

  def message({:restore_incomplete, %{safety_backup: safety}}, _ctx),
    do:
      "The restore failed partway through. The notebook may have lost anything written " <>
        "shortly before it, and that work survives only in backup #{safety}, taken just " <>
        "before the restore began — restore that backup to get it back."

  def message(:notebook_not_serving, _ctx),
    do:
      "The notebook is running, but the node cannot open its store: no notebook " <>
        "action except listing backups can succeed, and retrying will not change " <>
        "that. Ask the user to check the store and restart the Ymer Node app."

  def message(:notebook_restarted, _ctx),
    do:
      "The notebook restarted while that statement was running, so whether it took " <>
        "effect is unknown. Do not simply send it again — read the data back first, " <>
        "and repeat the statement only if it did not land."

  def message(
        {:restored_notebook_not_serving, %{restored: restored, safety_backup: safety}},
        _ctx
      ),
      do:
        "The restore completed: the notebook now holds backup #{restored}, safely on disk. " <>
          "But the node cannot open the store it now has, so no notebook action except " <>
          "listing backups can succeed. Do not retry — the restore already happened. Ask " <>
          "the user to check the store and restart the Ymer Node app. To undo the restore " <>
          "after that, restore backup #{safety}."

  # The refusal names what is true of every cause it covers — a file that is not a
  # database, and a disk that is full or read-only, refuse at the same statement
  # and the driver hands back no code to tell them apart — so it says the copy
  # could not be opened this time and never that the backup is beyond use.
  def message({:backup_unreadable, %{safety_backup: safety}}, _ctx),
    do:
      "That backup could not be opened as a database, so nothing was overwritten and " <>
        "the notebook is unchanged. A backup of the current state was saved as id " <>
        "#{safety} and is listed like any other. Choose a different backup from list; " <>
        "if every backup is refused, the cause is on the node's side — ask the user " <>
        "to check the node's disk and logs."

  # A refusal from the action layer rather than a failure from either context, so
  # it has to be enough on its own to fix the call. The value echoed back is the
  # caller's own and leaks nothing — and it is bounded by `show/1`, because no
  # value the caller sent may turn the answer into a dump. Placed above the two
  # catch-alls below, which match any reason and would otherwise swallow this one.
  def message({:wrong_type, %{key: key, expected: expected, got: got}}, _ctx),
    do: "#{key} must be #{expected}; got #{show(got)}. Send #{key} as a JSON string."

  def message(reason, %{action_verb: verb}), do: "Failed to #{verb}: #{inspect(reason)}"
  def message(reason, _ctx), do: "Operation failed: #{inspect(reason)}"

  # `inspect/2`'s own bounds do not cover every shape a caller can send: `:limit`
  # bounds the terms inside a collection and a bignum is a single term, while
  # `:printable_limit` bounds binaries. A large numeric literal therefore rendered
  # every one of its digits, at a cost that grows faster than their count — so an
  # integer is refused by magnitude BEFORE it is rendered, which is where that
  # cost sits: bare, here, and nested, by the walk below. The comparison is cheap
  # at any size, because bignums of different widths compare on width. Every other
  # shape is sliced AFTER rendering, and the cut is marked so a shortened echo
  # never reads as the value the caller sent. The framework's own
  # `Wymcp.Telemetry.Logger.bounded/1` bounds a bare integer only.
  defp show(got) when is_integer(got) and abs(got) >= @echo_integer_ceiling,
    do: "a number too large to echo"

  defp show(got) do
    rendered = got |> bound() |> inspect(limit: @echo_terms, printable_limit: 60)

    if String.length(rendered) > @echo_characters,
      do: String.slice(rendered, 0, @echo_characters) <> "...",
      else: rendered
  end

  # The walk covers the shapes JSON can carry — integers, arrays and objects; every
  # other term passes through — and stops where `inspect/2`'s `:limit` would, one
  # entry past it so the `...` marker still appears. `:limit` bounds depth as well
  # as breadth, so a deeply nested value costs the walk its depth and no more, and
  # a wide object costs its first entries, never a scan of every key.
  defp bound(int) when is_integer(int) and abs(int) >= @echo_integer_ceiling,
    do: "a number too large to echo"

  defp bound(list) when is_list(list),
    do: list |> Enum.take(@echo_terms + 1) |> Enum.map(&bound/1)

  # Through `:maps.iterator/1`, not `Enum.take/2`: the `Enumerable` impl for maps
  # lists the whole map before taking, which is the every-key scan this avoids.
  defp bound(map) when is_map(map) and not is_struct(map) do
    map
    |> :maps.iterator()
    |> take_entries(@echo_terms + 1, [])
    |> Map.new(fn {key, value} -> {key, bound(value)} end)
  end

  defp bound(other), do: other

  defp take_entries(_iterator, 0, taken), do: taken

  defp take_entries(iterator, remaining, taken) do
    case :maps.next(iterator) do
      :none -> taken
      {key, value, rest} -> take_entries(rest, remaining - 1, [{key, value} | taken])
    end
  end
end
