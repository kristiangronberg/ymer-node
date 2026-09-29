defmodule YmerNode.Repo.Migrations.CreateCacheEntries do
  use Ecto.Migration

  # One row per reference: what the script its recipe names last answered for
  # it, and when. The reference holds it — `on_delete: :delete_all` makes
  # "removing a reference removes its cache entry" a rule of the database — and
  # the unique index makes "one entry per reference" one too.
  #
  # The content is in exactly one of two places: `body` for a script that
  # stores text, in this row, or `path` for one that stores files, relative to
  # the cache directory. The CHECK makes a row holding both, or neither, a
  # database error rather than a state some reader has to decide about.
  #
  # `reference_validator` is the script's own string, kept and handed back,
  # never read by the node; `script` is the name of the script that filled the
  # row, because a validator means something only to the script that issued it.
  # `uri` and `fragment` are the target the row was fetched for, so a row whose
  # target the reference no longer names is never served as current.
  def change do
    create table(:cache_entries) do
      add :reference_id, references(:reference_entries, on_delete: :delete_all), null: false
      add :uri, :text, null: false
      add :fragment, :text, null: false, default: ""
      add :script, :string, null: false
      add :format, :string, null: false
      add :body, :text

      add :path, :string,
        check: %{name: "cache_entries_body_or_path", expr: "(body IS NULL) <> (path IS NULL)"}

      add :size_bytes, :integer, null: false
      add :reference_validator, :text
      add :fetched_at, :utc_datetime, null: false
      add :checked_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:cache_entries, [:reference_id])
  end
end
