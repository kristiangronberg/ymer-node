defmodule YmerNode.Repo.Migrations.CreateReferenceEntries do
  use Ecto.Migration

  # One row per reference. The table is `reference_entries` and not
  # `references`, which collides with the SQL keyword and is a footgun in any
  # hand-written statement.
  #
  # fragment is NOT NULL DEFAULT '' — deliberately not nullable — so the
  # (uri, fragment) unique index bites on exact re-adds: SQLite treats NULLs as
  # distinct in a unique index, and a nullable fragment would let the same uri
  # be inserted twice.
  #
  # tags is `{:array, :string}`, which ecto_sqlite3 stores as JSON text, and is
  # left nullable. An add or update that omits tags still writes a JSON array —
  # Ecto merges the schema's `[]` default into the insert — but an explicit JSON
  # null is a value the caller meant to send, so clearing the field stores a real
  # NULL, and a bulk import filling this table from outside the changeset may
  # write one too. The tag filter coalesces to '[]' rather than assuming a value,
  # for exactly those rows.
  def change do
    create table(:reference_entries) do
      add :title, :string, null: false
      add :description, :text
      add :uri, :text, null: false
      add :fragment, :text, null: false, default: ""
      add :tags, {:array, :string}

      timestamps(type: :utc_datetime)
    end

    # One reference per (uri, fragment). The same uri with different fragments
    # is legitimately two references — two sections of one page — so the pair,
    # not the uri alone, is the identity.
    create unique_index(:reference_entries, [:uri, :fragment])
  end
end
