defmodule YmerNode.References do
  @moduledoc """
  The registry of pointers at where knowledge lives, served to LLM workers as
  the `references` tool, and beside it the cache of what their targets say —
  § The membrane is the rule between the two.

  ## The membrane

  A reference is a pointer, never content. Its row records where knowledge
  lives and when to look — a title, the uri that is both identity and deep
  link, and a description that is local routing knowledge — and never what
  the target says. What the target says lives only in the cache: fetched by
  a script, never by the node itself; a mirror that may be behind the
  remote and is never ahead of it; stamped with when it was fetched and
  last checked; never pasted into a description, and never replicated to
  ymer. A copy in a description goes stale unseen. A cache entry says its
  age.

  That is the rule the node inherits along with the registry, and it is why
  `remove` is a hard delete: a pointer has no history worth preserving, and
  its cache entry goes with it, content the target can always fill again.
  The cache itself is `YmerNode.References.Cache`.

  ## The schemas

  ```mermaid
  erDiagram
      REFERENCE ||--o| CACHE_ENTRY : "cached as"
      REFERENCE {
          integer id PK
          string title
          string uri
          string fragment
      }
      CACHE_ENTRY {
          integer id PK
          integer reference_id FK
          string script
          string format
          text body
          string path
          string reference_validator
          datetime fetched_at
          datetime checked_at
      }
  ```

  ## Coordination

  Owned sub-modules against external dependencies:

  ```mermaid
  flowchart TD
      R[YmerNode.References]

      subgraph owned
          Reference[Reference schema]
          Sources
          Search
          Cache
      end

      subgraph external
          Repo[(YmerNode.Repo)]
          Scripts[YmerNode.Scripts]
      end

      R --> Reference
      R -->|"source filter"| Sources
      R -->|"find_references/1"| Search
      R -->|"drop on a moved uri, and on remove"| Cache
      R --> Repo
      Search -->|"list_classified/1"| R
      Search -->|"search_text/1"| Reference
      Cache -->|"the recipe"| Sources
      Cache -->|"run/3 on the URL action"| Scripts
  ```

  The `Search --> R` back-edge is deliberate and runtime-only — a `defdelegate`
  out and a plain call back, so there is no compile-time cycle. It exists so the
  tag-AND SQL, the source filter and the ordering stay implemented once, here,
  rather than a second time in the ranking layer.

  ## Design decisions

  - Derived, not stored: a reference's source and fetch recipe are computed from
    its uri at read time (`YmerNode.References.Sources`), so the set of accepted
    scripts, not a migration, is what decides how an old reference resolves.
  - `create_reference/1` maps the `(uri, fragment)` unique-index violation to
    `{:error, {:duplicate, existing}}`, so an exact re-add can be answered by
    pointing at the row that already exists instead of forking the registry.
  - Filters split by mechanism. Tags are SQL — one `json_each` membership
    `EXISTS` per required tag — while the source filter and every ordering run
    in Elixir after the load: source is derived and has no column to filter on,
    and SQLite's `lower()` folds ASCII only, so an Elixir sort is what makes
    a non-ASCII title order correctly. The registry is small by design and a
    full load per read is the settled cost.
  - **Classify once, and carry it.** `list_classified/1` is the primitive and
    `list_references/1` is the projection, not the other way round. The source
    filter has to classify every candidate to decide anything, so the result is
    kept beside the reference rather than thrown away and re-derived by the
    renderer. `YmerNode.References.Sources.declarations/0` is a query, and an
    operation reads it once and threads it down through `:declarations`.
  - No broadcast and no subscription. The node has no UI, so there is no open
    list to keep live; the tool call that mutates a reference is also the one
    that reports it.
  - A changed `uri` or `fragment` drops the cache entry. An entry fetched for
    the old target and served under a fresh stamp for the new one is the lie
    the membrane exists to prevent; the next read fetches the new target. A
    change to the title, description or tags keeps it.
  """

  import Ecto.Query, warn: false

  alias YmerNode.References.{Cache, Reference, Sources}
  alias YmerNode.Repo

  @doc """
  Lists references, each already classified. Options:

  - `:tags` — a list of tag strings; a reference must carry ALL of them
    (tag-AND, evaluated in SQL)
  - `:source` — a source token; evaluated in Elixir, because a source is derived
    from the uri at read time and has no column to filter on
  - `:order` — `:title` (default, downcased) or `:recent` (updated_at desc, then
    id desc)
  - `:declarations` — the seam, already read by the caller. Omit it and this
    function reads it once itself.

  Each entry is `%{reference: %YmerNode.References.Reference{}, classification:
  %{source: source, recipe: recipe}}`. The classification travels **with** the
  reference rather than being derived again downstream: the source filter has to
  classify every candidate to decide anything, and a renderer that classified a
  second time would do the same work twice on the same row and could, if the two
  reads straddled an `accept`, disagree with itself inside one response.
  """
  def list_classified(opts \\ []) when is_list(opts) do
    # `||` and not `Keyword.get_lazy/3`: a caller threading an option through
    # passes the key with a nil value, which a presence check would take for a
    # deliberate "no declarations". An empty LIST is falsy in neither sense and
    # is honoured as the real answer it is.
    declarations = opts[:declarations] || Sources.declarations()

    Reference
    |> apply_tags(opts[:tags])
    |> Repo.all()
    |> Enum.map(&%{reference: &1, classification: Sources.classify(&1.uri, declarations)})
    |> filter_source(opts[:source])
    |> sort_classified(opts[:order] || :title)
  end

  @doc """
  Lists references without their classifications — `list_classified/1` for a
  caller that only wants the rows.

  Takes the same options, `:declarations` included: a `:source` filter still has
  to classify, so passing the seam still saves the read.
  """
  def list_references(opts \\ []) when is_list(opts) do
    opts |> list_classified() |> Enum.map(& &1.reference)
  end

  def get_reference(id) do
    with {:ok, id} <- cast_id(id) do
      case Repo.get(Reference, id) do
        nil -> {:error, :not_found}
        %Reference{} = reference -> {:ok, reference}
      end
    end
  end

  @doc """
  Creates a reference.

  An insert that trips the `(uri, fragment)` unique index returns
  `{:error, {:duplicate, existing_reference}}` — the duplicate contract, which
  lets the caller steer to the existing row. In the vanishingly unlikely race
  where that row is deleted between the failed insert and the lookup, the plain
  changeset error is returned instead.
  """
  def create_reference(attrs) when is_map(attrs) do
    case %Reference{} |> Reference.changeset(attrs) |> Repo.insert() do
      {:ok, reference} ->
        {:ok, reference}

      {:error, changeset} ->
        with true <- unique_violation?(changeset),
             %Reference{} = existing <- lookup_existing(changeset) do
          {:error, {:duplicate, existing}}
        else
          _not_a_duplicate -> {:error, changeset}
        end
    end
  end

  @doc """
  Updates a reference's fields.

  Non-raising on a stale row: a bare-struct `Repo.update` against a row deleted
  out from under it raises `Ecto.StaleEntryError`, which degrades to
  `{:error, :not_found}` — the tool layer holds a `%Reference{}` across the
  window between reading it and writing it back.

  An update that moves the `uri` or the `fragment` drops the reference's cache
  entry, so the next read fetches the target the reference now names.
  """
  def update_reference(%Reference{} = reference, attrs) when is_map(attrs) do
    with {:ok, updated} <- reference |> Reference.changeset(attrs) |> Repo.update() do
      if moved?(reference, updated), do: Cache.drop(updated.id)
      {:ok, updated}
    end
  rescue
    Ecto.StaleEntryError -> {:error, :not_found}
  end

  @doc """
  Permanently deletes a reference, and its cache entry and that entry's file
  with it; the database takes the reference's watch.

  Uses a conditional `Repo.delete_all` rather than a bare-struct `Repo.delete`,
  so a double delete degrades to `{:error, :not_found}` instead of raising
  `Ecto.StaleEntryError`. The database's cascade takes the cache entry; its
  file, which is not the database's to remove, is named before the delete and
  removed after it — so a fetch still running cannot put an entry back
  between the two.
  """
  def delete_reference(%Reference{} = reference) do
    file = Cache.file_of(reference.id)

    case Repo.delete_all(from r in Reference, where: r.id == ^reference.id) do
      {1, _} ->
        Cache.discard_file(file)
        {:ok, reference}

      {0, _} ->
        {:error, :not_found}
    end
  end

  @doc "The ranked find surface — `YmerNode.References.Search.run/1` owns the mode contract."
  defdelegate find_references(opts \\ []), to: YmerNode.References.Search, as: :run

  @doc """
  Parses a reference id: a positive integer, or its string form. Pure, and the
  one place the accepted id form lives.

  ## Examples

      iex> YmerNode.References.parse_id(7)
      {:ok, 7}

      iex> YmerNode.References.parse_id(" 7 ")
      {:ok, 7}

      iex> YmerNode.References.parse_id("banana")
      :error

      iex> YmerNode.References.parse_id(0)
      :error

  """
  def parse_id(id) when is_integer(id) and id > 0, do: {:ok, id}

  def parse_id(id) when is_binary(id) do
    case Integer.parse(String.trim(id)) do
      {n, ""} when n > 0 -> {:ok, n}
      _not_a_positive_integer -> :error
    end
  end

  def parse_id(_id), do: :error

  # ─── Private helpers ────────────────────────────────────────────────

  # Maps a parse failure to :not_found, so a crafted id resolves cleanly instead
  # of crashing.
  defp cast_id(id) do
    case parse_id(id) do
      {:ok, n} -> {:ok, n}
      :error -> {:error, :not_found}
    end
  end

  defp moved?(reference, updated),
    do: reference.uri != updated.uri or reference.fragment != updated.fragment

  # Tag-AND: one json_each membership EXISTS per required tag.
  defp apply_tags(query, tags) when tags in [nil, []], do: query

  defp apply_tags(query, tags) when is_list(tags) do
    Enum.reduce(tags, query, fn tag, q ->
      where(
        q,
        [e],
        fragment(
          "EXISTS (SELECT 1 FROM json_each(COALESCE(?, '[]')) WHERE value = ?)",
          e.tags,
          type(^tag, :string)
        )
      )
    end)
  end

  # Filters on the classification each entry already carries, so no reference is
  # classified twice and no second read of the seam happens here.
  defp filter_source(entries, nil), do: entries

  defp filter_source(entries, source) when is_binary(source),
    do: Enum.filter(entries, &(&1.classification.source == source))

  defp sort_classified(entries, :title),
    do: Enum.sort_by(entries, &String.downcase(&1.reference.title))

  defp sort_classified(entries, :recent),
    do: Enum.sort_by(entries, &{-DateTime.to_unix(&1.reference.updated_at), -&1.reference.id})

  defp unique_violation?(%Ecto.Changeset{errors: errors}) do
    case Keyword.get(errors, :uri) do
      {_message, opts} -> Keyword.get(opts, :constraint) == :unique
      nil -> false
    end
  end

  defp lookup_existing(changeset) do
    Repo.get_by(Reference,
      uri: Ecto.Changeset.get_field(changeset, :uri),
      fragment: Ecto.Changeset.get_field(changeset, :fragment)
    )
  end
end
