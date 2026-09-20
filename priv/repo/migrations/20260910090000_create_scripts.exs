defmodule YmerNode.Repo.Migrations.CreateScripts do
  use Ecto.Migration

  # One row per script, and the row is the script: its code, the sha256 of that
  # code, and the hash this node has accepted. `run` refuses unless the two
  # hashes match, so acceptance is a comparison rather than a flag anything can
  # set by accident.
  #
  # `accepted_hash` and `accepted_at` are nullable because a row can exist
  # unaccepted — that is what a synced row will be when registry sync lands.
  # Every row written today is accepted at the write, by the door that wrote it.
  #
  # `description` and `declarations` are denormalised from the compiled module
  # at every write, so `list` and the references seam are one query and neither
  # needs a compiled module to answer. They are NOT the truth — the code is —
  # and a boot compile rewrites them if the module now says something else.
  #
  # `declarations` is a `:map`, which ecto_sqlite3 stores as JSON text through
  # the library `config/config.exs` names. It round-trips with string keys, and
  # the seam reads it that way.
  def change do
    create table(:scripts) do
      add :name, :string, null: false
      add :code, :text, null: false
      add :code_hash, :string, null: false
      add :accepted_hash, :string
      add :accepted_at, :utc_datetime
      add :origin, :string, null: false
      add :contract, :integer, null: false
      add :description, :text, null: false
      add :declarations, :map, null: false

      timestamps(type: :utc_datetime)
    end

    # The name is derived from the code's top module, so a unique name is also
    # a unique module tree: two rows sharing a name would compile over each
    # other in one VM.
    create unique_index(:scripts, [:name])
  end
end
