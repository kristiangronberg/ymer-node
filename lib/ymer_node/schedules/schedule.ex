defmodule YmerNode.Schedules.Schedule do
  @moduledoc """
  A standing instruction for the node to run one action of one accepted script,
  with fixed args, on a cron expression in the node time zone, until its lifetime
  ends — or a watch, a reference's own schedule, which names no script and no
  action because each firing derives the reference's recipe afresh
  (`YmerNode.Schedules` § Watches).

  A row in the node database, addressed by a name whoever added it chose —
  `morning-report` — which is unique on the node and fixed: renaming is removing
  and adding again. A name takes lowercase letters, digits, `-` and `_`, starting
  with a letter or digit: the throttle's rule, `t:YmerNode.Script.throttle/0`,
  so the names people type, hyphens and all, need no quoting at a shell.

  The script is held by its row, and the row's delete takes the schedule with it:
  the foreign key cascades, so removing a script can never leave a schedule
  pointing at nothing. A script's code replaced keeps its row, so a schedule
  follows the name to whatever is accepted under it at each firing. The script
  and the action are fixed at `add`; the cron expression, the args and the end
  are what `update` changes. A watch is held by its reference the same way, and
  a database CHECK keeps every row naming a script and its action or a
  reference, never both; one reference holds at most one watch.

  `ends_at` is where the lifetime ends; at or past it the schedule is expired
  and fires no more. The `last_*` fields are the last run, and nothing before it
  (`YmerNode.Schedules.LastRun`).
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias YmerNode.References.Reference
  alias YmerNode.Scripts.Script

  @name_format ~r/\A[a-z0-9][a-z0-9_-]*\z/

  @one_subject :schedules_run_a_script_or_watch_a_reference
  @one_subject_message "names a script and its action, or a reference — one of them"

  schema "schedules" do
    field :name, :string
    belongs_to :script, Script
    belongs_to :reference, Reference
    field :action, :string
    field :args, :map
    field :cron_expression, :string
    field :ends_at, :utc_datetime
    field :last_fired_at, :utc_datetime
    field :last_outcome, :string
    field :last_message, :string
    field :last_run_ms, :integer

    timestamps(type: :utc_datetime)
  end

  @doc """
  The changeset for a new schedule and for an update. `YmerNode.Schedules` checks
  every value before it gets here, so this is a backstop — except for the unique
  name, which only the database can settle between two adds racing each other.
  """
  def changeset(schedule, attrs) do
    schedule
    |> cast(attrs, [:name, :script_id, :action, :args, :cron_expression, :ends_at])
    |> validate_required([:name, :script_id, :action, :args, :cron_expression, :ends_at])
    |> validate_format(:name, @name_format)
    |> unique_constraint(:name)
    |> foreign_key_constraint(:script_id)
    |> check_constraint(:script_id, name: @one_subject, message: @one_subject_message)
  end

  @doc """
  The changeset for a watch, new or replaced: the name, the reference, the cron
  expression and the end — no script and no action. The backstop again, with
  the one-watch-per-reference rule the database settles.
  """
  def watch_changeset(schedule, attrs) do
    schedule
    |> cast(attrs, [:name, :reference_id, :args, :cron_expression, :ends_at])
    |> validate_required([:name, :reference_id, :args, :cron_expression, :ends_at])
    |> validate_format(:name, @name_format)
    |> unique_constraint(:name)
    |> unique_constraint(:reference_id)
    |> check_constraint(:reference_id, name: @one_subject, message: @one_subject_message)
  end

  @doc """
  Whether a name follows the rule.

  ## Examples

      iex> YmerNode.Schedules.Schedule.valid_name?("morning-report")
      true

      iex> YmerNode.Schedules.Schedule.valid_name?("Morning")
      false

      iex> YmerNode.Schedules.Schedule.valid_name?("-report")
      false

  """
  def valid_name?(name) when is_binary(name), do: Regex.match?(@name_format, name)
end
