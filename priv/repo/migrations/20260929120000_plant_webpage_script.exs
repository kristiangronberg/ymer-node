defmodule YmerNode.Repo.Migrations.PlantWebpageScript do
  use Ecto.Migration

  import Ecto.Query, only: [from: 2]

  require Logger

  # The second example script the image ships, `webpage` — the web fallback —
  # planted once as an accepted row of origin `shipped`, the way the migration
  # before it plants `hex`. A migration of its own because a recorded migration
  # never runs again: an install that already holds `hex` gets `webpage` from
  # this one and from nothing else. Its skip is its own too. An operator's
  # script that is already the web fallback keeps the part: the example is not
  # planted, the boot goes on, the log says why, and the record is written all
  # the same, so that install never gets the example from a boot. What the row
  # holds, and why its compile runs outside the loader, is
  # `YmerNode.Scripts.plant_example/1`'s.
  #
  # Runs at boot inside the node's own tree, for the reason the `hex`
  # migration gives, and `config/test.exs` turns the planting off here too.
  def up do
    if YmerNode.Scripts.plant_example?() do
      case YmerNode.Scripts.plant_example("webpage.exs") do
        {:ok, _script} ->
          :ok

        # Ahead of the clause below on purpose: this refusal has the shape of a
        # compile error, and it is the operator's prior choice, not a defect in
        # the shipped file.
        {:error, {:fallback_claimed, detail}} ->
          Logger.warning(
            "scripts: the webpage example script was not planted, and no later boot will " <>
              "plant it — #{detail}; to use it instead, drop that script's web fallback " <>
              "and import the release's own copy by hand: " <>
              "#{YmerNode.Scripts.example_path("webpage.exs")}"
          )

        {:error, {reason, detail}} ->
          raise "the webpage example script the build ships does not compile (#{reason}): " <>
                  detail
      end
    end
  end

  # Unplants only what `up` planted: the `webpage` row of origin `shipped`.
  def down do
    repo().delete_all(
      from script in "scripts", where: script.name == "webpage" and script.origin == "shipped"
    )
  end
end
