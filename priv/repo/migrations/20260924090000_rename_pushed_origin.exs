defmodule YmerNode.Repo.Migrations.RenamePushedOrigin do
  use Ecto.Migration

  # Remediation(inert): the CLI's verb for landing a file was `push` before it
  # became `import`, and every row it stored carries the origin `pushed`, a
  # word the node no longer writes or accepts. This rewrites those rows to
  # `imported` once, at the first boot of the release that renamed the verb.
  # plan: 2026-09-23-scripts-program-door
  #
  # Plain SQL on the table rather than the schema: a migration outlives the
  # schema it was written beside, and this one has to read the same on every
  # later release. `down` writes the old word back, so the version steps down
  # and up like every other migration here; it cannot tell a row imported after
  # the rename from one pushed before it, and the release it steps back to
  # reads either word as itself.
  def change do
    execute(
      "UPDATE scripts SET origin = 'imported' WHERE origin = 'pushed'",
      "UPDATE scripts SET origin = 'pushed' WHERE origin = 'imported'"
    )
  end
end
