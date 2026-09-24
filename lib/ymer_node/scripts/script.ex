defmodule YmerNode.Scripts.Script do
  @moduledoc """
  An Elixir module stored as a row in the node database — its code, the hash of
  that code and the hash this node has accepted — compiled into the VM and
  reachable through the `scripts` tool and by the node itself; `Script.<Name>`,
  named after its module.

  ## Acceptance is a comparison, not a flag

  `accepted?/1` is `accepted_hash == code_hash` and nothing else. There is no
  boolean to set, so no write can accept a row by forgetting to clear something:
  changing the code changes `code_hash`, and the row stops being runnable in the
  same write. `accepted_hash` is nullable because a row can legitimately exist
  unaccepted — that is what a synced row will be — and `nil` never equals a
  hash, so an unaccepted row is refused by the same comparison. `accepted/1` is
  that comparison as a query, so no reader of the table spells it a second time.

  What accepting means, and which doors may do it, is stated once in `YmerNode`'s
  Scripts section.

  ## The denormalised pair

  `description` and `declarations` are copied out of the compiled module at
  every write. They are not the truth — the code is — and a boot compile
  rewrites them when the module has come to say something else. They exist so
  that `list` and the references seam are one query each: classifying a
  reference must not need a compiled module, and `YmerNode.References.Sources`
  runs on every read.

  `declarations` is stored as JSON and comes back with **string** keys, which is
  the shape the seam wants; `t:YmerNode.Script.declarations/0` is the atom-keyed
  shape a script's callback returns, and `YmerNode.Scripts.Compiler` is where
  the two meet.

  ## What the changeset checks, and what it cannot

  Everything here is a value check on data the node itself produced one function
  earlier — the compiler derived the name, hashed the code and read the
  callbacks — so the changeset is a backstop against a bug in this codebase
  rather than against a caller. The checks that matter to a caller live
  upstream, in the compiler's parse and in acceptance's five refusals
  (`YmerNode.Scripts`).
  """
  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  @origins ~w(authored imported synced shipped)

  @cast_fields ~w(name code code_hash accepted_hash accepted_at origin contract
                  description declarations)a

  @typedoc """
  Which door a script row arrived through — `authored` (an MCP write),
  `imported` (the CLI), `synced` (registry sync, later), `shipped` (the build:
  the example script, planted on a fresh node database by a migration).

  Provenance, never permission: what a row may do is decided by `accepted?/1`,
  and this only records how it got here. It is a plain string rather than an
  Ecto enum so that a value the node does not know reads back as itself instead
  of raising on load.
  """
  @type origin :: String.t()

  schema "scripts" do
    field :name, :string
    field :code, :string
    field :code_hash, :string
    field :accepted_hash, :string
    field :accepted_at, :utc_datetime
    field :origin, :string
    field :contract, :integer
    field :description, :string
    field :declarations, :map

    timestamps(type: :utc_datetime)
  end

  def changeset(script, attrs) do
    script
    |> cast(attrs, @cast_fields)
    |> validate_required([
      :name,
      :code,
      :code_hash,
      :origin,
      :contract,
      :description,
      :declarations
    ])
    |> validate_inclusion(:origin, @origins)
    |> validate_format(:name, ~r/\A[a-z][a-z0-9_]*\z/)
    |> unique_constraint(:name)
  end

  @doc """
  Whether this row may run: its accepted hash equals its code hash.

  ## Examples

      iex> YmerNode.Scripts.Script.accepted?(%YmerNode.Scripts.Script{code_hash: "a", accepted_hash: "a"})
      true

      iex> YmerNode.Scripts.Script.accepted?(%YmerNode.Scripts.Script{code_hash: "a", accepted_hash: "b"})
      false

      iex> YmerNode.Scripts.Script.accepted?(%YmerNode.Scripts.Script{code_hash: "a", accepted_hash: nil})
      false

  """
  def accepted?(%__MODULE__{code_hash: hash, accepted_hash: hash}) when is_binary(hash), do: true
  def accepted?(%__MODULE__{}), do: false

  @doc """
  Narrows a query to the rows `accepted?/1` answers true for — the same
  comparison, spelled once for the database. `Script.accepted()` is the whole
  table so narrowed; pass a query to narrow one already built.
  """
  def accepted(query \\ __MODULE__) do
    from script in query, where: script.accepted_hash == script.code_hash
  end

  @doc """
  The sha256 of a script's code, lowercase hex — the value both hash columns
  hold.

  ## Examples

      iex> YmerNode.Scripts.Script.hash("")
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  """
  def hash(code) when is_binary(code) do
    :sha256 |> :crypto.hash(code) |> Base.encode16(case: :lower)
  end

  @doc "The origins a row may carry, in the order they were introduced."
  def origins, do: @origins
end
