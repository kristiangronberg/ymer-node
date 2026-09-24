defmodule YmerNode.Repo.Migrations.PlantExampleScript do
  use Ecto.Migration

  import Ecto.Query, only: [from: 2]

  require Logger

  # The example script the image ships is planted here, once, as an accepted
  # row of origin `shipped` — so a fresh install holds it without an operator
  # importing it by hand. A migration rather than a check at every boot because
  # this table's own record is the memory: a recorded migration never runs
  # again, so removing the row sticks, an upgrade never re-plants it, and a
  # rebuilt node database plants it again with everything else it recreates. A
  # row of the example's name already here — an operator's import — is kept
  # as it is, and so is an operator's script that already claims the example's
  # host: the example is then not planted, the boot goes on, and the log says
  # why — the way the loader goes on past a row that will not compile, because
  # a boot that died over one script would take the notebook and the registry
  # with it, on every boot until someone found the row. The record is written
  # either way, so that install never gets the example from a boot: an operator
  # who frees the host and wants it imports the release's own copy by hand
  # (`priv/scripts/hex.exs` under the release's `lib/ymer_node-<version>/`).
  # What the row holds, and why its compile runs outside the loader, is
  # `YmerNode.Scripts.plant_example/0`'s.
  #
  # Runs at boot, inside the node's own tree: the compile needs the task
  # supervisor the tree starts ahead of the migrator, so a `mix ecto.migrate`
  # run outside the tree would not reach it. `config/test.exs` turns the
  # planting off, so a test database never holds a row no case wrote.
  def up do
    if YmerNode.Scripts.plant_example?() do
      case YmerNode.Scripts.plant_example() do
        {:ok, _script} ->
          :ok

        # Ahead of the clause below on purpose: this refusal is the same shape
        # as a compile error, and it is the operator's prior choice, not a
        # defect in the shipped file.
        {:error, {:host_claimed, detail}} ->
          Logger.warning(
            "scripts: the example script was not planted, and no later boot will plant it — " <>
              "#{detail}; once the host is free, import the release's own copy by hand: " <>
              "#{YmerNode.Scripts.example_path()}"
          )

        {:error, {reason, detail}} ->
          raise "the example script the build ships does not compile (#{reason}): #{detail}"
      end
    end
  end

  # Unplants only what `up` planted: the row of origin `shipped`.
  def down do
    repo().delete_all(from script in "scripts", where: script.origin == "shipped")
  end
end
