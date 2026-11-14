defmodule YmerNode.Repo.Migrations.AddKindAndVersionToScripts do
  use Ecto.Migration

  # Remediation(permanent): dated just after the migration that creates the
  # table and ahead of the migrations that plant the example scripts, which
  # write through the current schema and so need both columns on a fresh node
  # database. A node that already ran those migrations runs this one as pending
  # at its next boot, as Ecto runs every migration it has not recorded. Moving
  # its version later breaks every fresh node. plan: 2026-11-13-script-libraries
  #
  # A row is a script or a library, and it carries its author's version, read
  # from the code's `version/0` at every write like the description. `kind`
  # defaults to `script`, which every row written before libraries existed is.
  # `version` is nullable because those rows have none: their code has no
  # `version/0`, so each is kept Broken at boot until it is stored again.
  def change do
    alter table(:scripts) do
      add :kind, :string, null: false, default: "script"
      add :version, :string
    end
  end
end
