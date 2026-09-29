defmodule YmerNode.Repo.Migrations.AddWatchesToSchedules do
  use Ecto.Migration

  # A schedule now runs one action of one script, or is a watch: a
  # reference's own schedule, which names no script and no action, because
  # each firing derives the reference's recipe afresh. So `script_id` and
  # `action` become nullable and `reference_id` joins them — held by the
  # reference, and deleted with it as a script's schedules are with the script.
  #
  # SQLite cannot drop a NOT NULL in place, so the table is rebuilt: a new one
  # beside it, every row copied, the old one dropped, the new one renamed, and
  # the indexes made again. Nothing references `schedules`, so dropping and
  # renaming it touches no other table. The CHECK makes a row that names
  # neither a script nor a reference, or both, or a script with no action, a
  # database error; the unique index on `reference_id` makes "one watch per
  # reference" a rule of the database too. `down` removes every watch and
  # rebuilds the table as it was.
  @columns "id, name, script_id, action, args, cron_expression, ends_at, last_fired_at, " <>
             "last_outcome, last_message, last_run_ms, inserted_at, updated_at"

  def up do
    create table(:schedules_rebuilt) do
      add :name, :string, null: false
      add :script_id, references(:scripts, on_delete: :delete_all)

      add :reference_id, references(:reference_entries, on_delete: :delete_all),
        check: %{
          name: "schedules_run_a_script_or_watch_a_reference",
          expr:
            "(script_id IS NULL) <> (reference_id IS NULL) AND " <>
              "(script_id IS NULL OR action IS NOT NULL)"
        }

      add :action, :string
      add :args, :map, null: false
      add :cron_expression, :string, null: false
      add :ends_at, :utc_datetime, null: false
      add :last_fired_at, :utc_datetime
      add :last_outcome, :string
      add :last_message, :text
      add :last_run_ms, :integer

      timestamps(type: :utc_datetime)
    end

    execute("INSERT INTO schedules_rebuilt (#{@columns}) SELECT #{@columns} FROM schedules")
    drop table(:schedules)
    rename table(:schedules_rebuilt), to: table(:schedules)

    create unique_index(:schedules, [:name])
    create index(:schedules, [:script_id])
    create unique_index(:schedules, [:reference_id])
  end

  def down do
    execute("DELETE FROM schedules WHERE script_id IS NULL")

    create table(:schedules_rebuilt) do
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

    execute("INSERT INTO schedules_rebuilt (#{@columns}) SELECT #{@columns} FROM schedules")
    drop table(:schedules)
    rename table(:schedules_rebuilt), to: table(:schedules)

    create unique_index(:schedules, [:name])
    create index(:schedules, [:script_id])
  end
end
