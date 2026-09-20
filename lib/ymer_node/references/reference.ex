defmodule YmerNode.References.Reference do
  @moduledoc """
  One row of the registry: a pointer naming where knowledge lives and when to
  look, never what it says. The rule that keeps it a pointer — the membrane —
  is stated in `YmerNode.References`.

  Shape decisions:

  - The uri is both the identity and the deep link. A reference's source and
    fetch recipe are DERIVED from it at read time
    (`YmerNode.References.Sources`) and never stored, so accepting a script
    upgrades every reference pointing at the hosts it claims, retroactively —
    and un-accepting it downgrades them in the same moment.
  - `fragment` locates content within the target and is stored as `""` when
    absent, never NULL, because SQLite treats NULLs as distinct in a unique
    index: a nullable fragment would let the same uri be added twice. The same
    uri with different fragments is legitimately two references — two sections
    of one page.
  - uri equality is byte-equality after a whitespace trim. There is no
    canonicalization: http and https, and a trailing slash, make distinct
    references. Near-duplicates are grooming's problem, and a canonicalizer
    would have to guess which of two spellings the user meant.
  - `tags` are free text, cast but never validated. The vocabulary is the
    user's, and it is the only thing binding a reference to anything else.
  - `title` and `uri` are required; `title` must clear a two-character floor and
    a 255-character ceiling. The ceiling is enforced here rather than only
    declared in the tool's JSON schema, which nothing checks at runtime.

  `search_text/1` is the keyword projection every find ranks against.
  """
  use Ecto.Schema

  import Ecto.Changeset

  @cast_fields ~w(title description uri fragment tags)a

  schema "reference_entries" do
    field :title, :string
    field :description, :string
    field :uri, :string
    field :fragment, :string, default: ""
    field :tags, {:array, :string}, default: []

    timestamps(type: :utc_datetime)
  end

  def changeset(reference, attrs) do
    reference
    |> cast(attrs, @cast_fields)
    |> update_change(:title, &trim/1)
    |> update_change(:uri, &trim/1)
    |> normalize_fragment()
    |> validate_required([:title, :uri])
    |> validate_length(:title, min: 2, max: 255)
    |> unique_constraint([:uri, :fragment])
  end

  @doc """
  The keyword-search projection: title, description, fragment, uri and tags
  joined with newlines, skipping the empty ones.

  Every text field is in it deliberately, so a term carried only by the uri —
  an issue key, a page id — matches a reference whose prose never mentions it.
  """
  def search_text(%__MODULE__{} = reference) do
    [
      reference.title,
      reference.description,
      reference.fragment,
      reference.uri,
      Enum.join(reference.tags || [], " ")
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  # An absent fragment must land as "" and not NULL for the unique index to
  # bite. `cast/3` replaces an empty value with the struct default — already ""
  # here — so absent and blank params need no help. The one path that records a
  # nil change is an EXPLICIT nil param, which is what a JSON null arriving
  # through the tool boundary is. Trim any binary change first, then force the
  # nil to "".
  defp normalize_fragment(changeset) do
    changeset = update_change(changeset, :fragment, &trim/1)

    case get_field(changeset, :fragment) do
      nil -> put_change(changeset, :fragment, "")
      _present -> changeset
    end
  end

  # nil-SAFE, because `update_change/3` applies its function to a recorded nil
  # change, and an explicit nil param records one — a JSON null at the tool
  # boundary. A bare `String.trim/1` here raises `FunctionClauseError` ten
  # frames down; passing the nil through lets `validate_required` answer "can't
  # be blank" instead. The two clauses are exhaustive: the `:string` cast
  # rejects a non-binary, non-nil param with a cast error and records no change.
  defp trim(nil), do: nil
  defp trim(value) when is_binary(value), do: String.trim(value)
end
