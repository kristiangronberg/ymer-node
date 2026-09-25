defmodule YmerNode.Repo.Migrations.CreateSchedules do
  use Ecto.Migration

  # One row per schedule. The script is held by its row id, and the row is
  # deleted with the script: `on_delete: :delete_all` makes "removing a script
  # removes its schedules" a rule of the database rather than of every door
  # that removes one. It fires because SQLite's foreign keys are on for this
  # repo — exqlite's own default, which no config here overrides.
  #
  # `args` is a `:map`, stored as JSON text like a script's declarations, and
  # comes back with string keys — the shape a run's args arrive in.
  #
  # The `last_*` columns are the last run and nothing before it; they are
  # nullable because a schedule that has not fired yet has none.
  def change do
    create table(:schedules) do
      add :name, :string, null: false
      add :script_id, references(:scripts, on_delete: :delete_all), null: false
      add :action, :string, null: false
      add :args, :map, null: false
      add :cron_expression, :string, null: false
      add :ends_at, :utc_datetime, null: false
      add :last_fired_at, :utc_datetime
      add :last_outcome, :string
      add :last_message, :text
      add :last_run_ms, :integer

      timestamps(type: :utc_datetime)
    end

    # The name is how every door addresses a schedule, so it is unique on the node.
    create unique_index(:schedules, [:name])
    create index(:schedules, [:script_id])
  end
end
