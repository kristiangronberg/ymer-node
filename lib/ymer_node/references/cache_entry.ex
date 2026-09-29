defmodule YmerNode.References.CacheEntry do
  @moduledoc """
  One reference's cache entry: what the script its fetch recipe names last
  answered for it, and when. How an entry is filled, refreshed and served is
  `YmerNode.References.Cache`'s; this is the row.

  Shape decisions:

  - One entry per reference, held by it: the reference's delete takes the row
    with it, and the unique index refuses a second.
  - The content sits in exactly one of `body` (text, in the node database) or
    `path` (a file, relative to the cache directory) — which one follows the
    script's `cache` declaration. A database CHECK refuses both and neither.
  - `format` is the media type the script answered, and it alone decides how
    the entry is served — never where the bytes are kept.
  - `script` names the script that filled the entry. A `reference_validator`
    means something only to the script that issued it, so an entry filled by
    another script than the one the recipe names today is not handed to the new
    one.
  - `uri` and `fragment` are the target the entry was fetched for — the
    reference's at that moment. An entry whose target is not the one the
    reference names now is a miss, whatever wrote it.
  - An empty `body` is a page with no text, and is kept as one: the changeset
    casts no value to nil, so `""` is a body and not an absent one.
  - `fetched_at` is when the content last changed as far as the node knows —
    the last full answer — and `checked_at` when the script was last asked,
    which an unchanged answer moves alone.
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias YmerNode.References.Reference

  @fields ~w(reference_id uri fragment script format body path size_bytes reference_validator
             fetched_at checked_at)a

  @required ~w(reference_id uri script format size_bytes fetched_at checked_at)a

  schema "cache_entries" do
    belongs_to :reference, Reference
    field :uri, :string
    field :fragment, :string, default: ""
    field :script, :string
    field :format, :string
    field :body, :string
    field :path, :string
    field :size_bytes, :integer
    field :reference_validator, :string
    field :fetched_at, :utc_datetime
    field :checked_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc """
  The changeset for a new entry and for a refetch. `YmerNode.References.Cache`
  builds every value, so this is a backstop — except for the one-body-or-path
  rule and the one entry per reference, which the database settles.
  """
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, @fields, empty_values: [])
    |> validate_required(@required)
    |> check_constraint(:body,
      name: :cache_entries_body_or_path,
      message: "holds a body or a path, never both and never neither"
    )
    |> unique_constraint(:reference_id)
    |> foreign_key_constraint(:reference_id)
  end
end
