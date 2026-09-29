defmodule YmerNode.References.Cache do
  @moduledoc """
  The cache: what the targets of this node's references say, fetched by each
  reference's own script and kept here — one cache entry per reference, text
  in the node database, files in the cache directory. What the cache is for,
  and the rule that keeps a reference a pointer while its content lives here,
  is `YmerNode.References` § The membrane.

  The node never fetches. Filling a cache entry is running the reference's fetch
  recipe — the URL action `YmerNode.References.Sources` derives for its uri at
  this moment — through `YmerNode.Scripts.run/3`, the door every run takes, and
  keeping what it answers. Read-only, never a working copy — how far an entry
  may lag its target is the membrane's — and every answer about one says how
  old it is.

  ```mermaid
  flowchart TD
      Cache[YmerNode.References.Cache]

      subgraph owned
          Entry[CacheEntry schema]
          Window
          Reconcile
      end

      subgraph external
          Sources[References.Sources]
          Scripts[YmerNode.Scripts]
          Repo[(YmerNode.Repo)]
          Dir[(cache directory)]
      end

      Cache -->|"the recipe, at this moment"| Sources
      Cache -->|"run/3 on the URL action"| Scripts
      Cache --> Entry
      Cache -->|"a text entry's lines"| Window
      Cache --> Repo
      Cache -->|"file entries"| Dir
      Reconcile -->|"at boot: unnamed files go"| Dir
  ```

  ## Filling a cache entry

  The URL action is called with the reference's uri under `url`, its fragment
  under `fragment` where it has one, and — when the entry was filled by the
  same script — the `reference_validator` that script answered last time. A
  script that stores files (`cache: :file` in its declarations) is also
  handed `cache_path`, an absolute path in the cache directory to write the
  bytes to: a fresh name for every run, renamed into place when the answer is
  kept and deleted when it is not, so two refreshes of one reference never
  write one file.

  What the action may answer, and what the node makes of it:

  | answer | the node |
  | --- | --- |
  | `%{"unchanged" => true}`, with an entry from that script to keep | keeps the entry, moves its `checked_at` |
  | `%{"content" => text, "format" => type, "reference_validator" => v}` from a text-storing script, `type` a `text/*` one | guards the text and keeps it, stamping `fetched_at` and `checked_at` |
  | `%{"format" => type, "reference_validator" => v}` from a file-storing script that wrote `cache_path` | keeps the file, named for the reference |
  | anything else | refuses as `:not_cache_contract`, naming the script as one that predates the contract |

  `format` is a media type and defaults to `text/markdown`; a script that
  stores text answers a `text/*` one, because text is all a text entry can be
  served as — anything else is converted first, or kept by a script that
  stores files. Text is kept up to `text_limit/0` bytes.
  `reference_validator` is optional, the script's own string, and never read
  here. The text guard is the runner's and one of its own: an answer that is
  not valid UTF-8 never encodes and is refused by `YmerNode.Scripts.Runner` as
  `:result_not_encodable`; text carrying a NUL byte is refused here as
  `:not_text`. Every refusal — a script's error, a timeout, a guard — keeps
  the entry that was there.

  A cache entry records the target it was fetched for — the reference's uri
  and fragment — and the reference is read again once the run is over: an
  answer for a target the reference no longer names, because it was moved or
  removed while the run was in flight, is refused as `:reference_changed`
  and never kept.

  A cache entry records the script that filled it. When the recipe names
  another script today — a new claim on the host, a script removed, the web
  fallback taking over — the entry is a miss, refetched by the new script with
  no validator, because a validator means something only to the script that
  issued it; the file the replaced entry named, if any, goes with it. An entry
  fetched for another target than the reference names now is a miss too, and
  so is a file entry whose file is gone. A reference no script fetches any
  more has its entry dropped.

  ## Serving a cache entry

  `format` alone decides how an entry is served, never where it is kept:

  - `text/*` by line window (`YmerNode.References.Cache.Window`); a file
    entry's text is guarded as it is read;
  - `image/png`, `image/jpeg`, `image/gif` and `image/webp`, stored as a file
    and no larger than `image_limit/0` once base64-encoded, as image content;
  - anything else — only ever a file entry, since text is kept only as
    `text/*` — is described: its format, its size and its path relative to the
    cache directory, because a model cannot read it as it stands, and a script
    meant for one should convert it.

  An image's size is taken from the file before it is read, so an image over
  the limit is never loaded to be refused.

  ## The cache directory

  `dir/0`. The node's, not the user's: a sibling of the files directory under
  the mount, never inside it, and rebuildable together with the node database:
  it follows the database. At boot `YmerNode.References.Cache.Reconcile`
  removes every file in it that carries the node's naming and that no entry
  names, so a fresh node database empties it and a run cut short leaves nothing
  behind, and it removes every entry whose file is gone. Between boots an entry
  whose file is gone is a miss, fetched again on the next read.
  """
  import Ecto.Query, warn: false

  alias YmerNode.References.Cache.Window
  alias YmerNode.References.{CacheEntry, Reference, Sources}
  alias YmerNode.Repo
  alias YmerNode.Scripts

  # Base64-encoded bytes, the size an image block carries: just under the
  # 5 MB a model is known to take.
  @image_limit 4_900_000

  # Text kept in the node database, in bytes: a page larger than this is
  # refused rather than stored, since every read loads an entry's body whole.
  @text_limit 5_000_000

  @served_images ~w(image/png image/jpeg image/gif image/webp)

  @extensions %{
    "image/png" => "png",
    "image/jpeg" => "jpg",
    "image/gif" => "gif",
    "image/webp" => "webp",
    "application/pdf" => "pdf",
    "text/plain" => "txt",
    "text/markdown" => "md",
    "text/html" => "html",
    "text/csv" => "csv"
  }

  @entry_file ~r/\A\d+\.[a-z0-9]+\z/
  @part_file ~r/\A\d+\.part-\d+\z/

  # ─── Runtime configuration ──────────────────────────────────────────

  @doc """
  The cache directory, an absolute path — `config :ymer_node,
  YmerNode.References.Cache, :dir`, which `config/runtime.exs` writes from
  `CACHE_PATH` in the prod environment and `config/dev.exs` and
  `config/test.exs` name for their own. An absent key is a configuration
  defect this refuses by name.
  """
  def dir do
    case :ymer_node |> Application.get_env(__MODULE__, []) |> Keyword.fetch(:dir) do
      {:ok, directory} ->
        directory

      :error ->
        raise ArgumentError,
              "no cache directory is configured: `config :ymer_node, " <>
                "YmerNode.References.Cache, dir:` is unset — the release writes it " <>
                "from CACHE_PATH, and dev and test each name their own"
    end
  end

  # ─── Public API ─────────────────────────────────────────────────────

  @doc "The largest image, in base64-encoded bytes, served as image content."
  def image_limit, do: @image_limit

  @doc "The largest text, in bytes, a text-storing script's answer is kept at."
  def text_limit, do: @text_limit

  @doc """
  The script and action that fetch a reference right now, and how that script
  stores — or `{:error, {:no_recipe, detail}}` naming the reference as a
  pointer only.

  Reads nothing: the declarations are the caller's one read of the seam.
  """
  def recipe(%Reference{} = reference, declarations) when is_list(declarations) do
    case Sources.classify(reference.uri, declarations) do
      %{recipe: %{params: %{"script" => script, "action" => action}}} ->
        mode = Enum.find_value(declarations, "text", &(&1.name == script && &1.cache))
        {:ok, %{script: script, action: action, cache: mode}}

      %{source: source} ->
        {:error,
         {:no_recipe,
          "no script fetches #{reference.uri} — its source is #{source}, which no accepted " <>
            "script serves, so reference ##{reference.id} is a pointer only"}}
    end
  end

  @doc """
  Runs the reference's recipe now and keeps what it answers, handing the
  entry's `reference_validator` back when the same script filled it.

  Answers `{:ok, %{outcome: "fetched" | "unchanged", entry: entry}}`, or the
  refusal — the entry that was there stays. A reference no script fetches has
  its entry dropped.
  """
  def refresh(%Reference{} = reference, declarations) when is_list(declarations) do
    with_recipe(reference, declarations, fn recipe ->
      fill(reference, recipe, stored(reference))
    end)
  end

  @doc """
  Serves a reference's entry, fetching it once when there is none or when
  another script than the recipe's filled it. `options` are the window's —
  `:offset`, `:limit` and `:column` — for a text entry.

  Answers `{:ok, %{entry: entry, fetched: boolean, served: served}}` where
  `served` is `{:text, window}`, `{:image, base64, media_type}` or
  `{:described, note}`, or the refusal `refresh/2` would give.
  """
  def read(%Reference{} = reference, declarations, options \\ [])
      when is_list(declarations) and is_list(options) do
    with_recipe(reference, declarations, fn recipe ->
      previous = stored(reference)

      case current(previous, reference, recipe) do
        %CacheEntry{} = entry -> {:ok, served(entry, false, options)}
        nil -> fetch_and_serve(reference, recipe, previous, options)
      end
    end)
  end

  @doc """
  Drops a reference's entry and its file, if it has one. Answers `:ok` either
  way: an entry that is not there is already dropped.
  """
  def drop(reference_id) when is_integer(reference_id) do
    path = file_of(reference_id)
    Repo.delete_all(from e in CacheEntry, where: e.reference_id == ^reference_id)
    remove_file(path)
  end

  @doc """
  The name of the file a reference's cache entry keeps, relative to the cache
  directory — nil when the entry keeps text, or there is none.
  """
  def file_of(reference_id) when is_integer(reference_id) do
    Repo.one(from e in CacheEntry, where: e.reference_id == ^reference_id, select: e.path)
  end

  @doc """
  Removes a file from the cache directory by the name `file_of/1` gave; nil is
  nothing to remove. For the caller that deleted the entry's reference, whose
  cascade took the row and left the file.
  """
  def discard_file(name) when is_binary(name) or is_nil(name), do: remove_file(name)

  @doc """
  Creates the cache directory, removes every file in it that carries the
  node's naming — `<reference id>.<extension>` or `<reference id>.part-<n>` —
  and that no entry names, and deletes every entry whose file is gone. Answers
  the file names it removed. Nothing else in the directory is touched.
  """
  def reconcile do
    File.mkdir_p!(dir())
    present = MapSet.new(File.ls!(dir()))
    entries = Repo.all(from e in CacheEntry, where: not is_nil(e.path), select: {e.id, e.path})
    {named, lost} = Enum.split_with(entries, fn {_id, path} -> MapSet.member?(present, path) end)
    lost_ids = Enum.map(lost, &elem(&1, 0))
    Repo.delete_all(from e in CacheEntry, where: e.id in ^lost_ids)
    named = MapSet.new(named, &elem(&1, 1))

    present
    |> Enum.filter(&(nodes_own?(&1) and not MapSet.member?(named, &1)))
    |> Enum.map(fn name ->
      File.rm(Path.join(dir(), name))
      name
    end)
    |> Enum.sort()
  end

  # ─── Filling ────────────────────────────────────────────────────────

  defp fetch_and_serve(reference, recipe, previous, options) do
    with {:ok, %{entry: entry}} <- fill(reference, recipe, previous) do
      {:ok, served(entry, true, options)}
    end
  end

  # `previous` is the row the reference holds, whoever filled it; `existing` is
  # that row only when it is current for this recipe, and only it hands its
  # validator on or is kept by an unchanged answer.
  defp fill(reference, recipe, previous) do
    existing = current(previous, reference, recipe)
    part = if recipe.cache == "file", do: part_path(reference.id)

    try do
      recipe.script
      |> Scripts.run(recipe.action, args(reference, existing, part))
      |> still_named(reference)
      |> keep(reference, recipe, existing, part)
      |> tidy_previous(previous)
    after
      if part, do: File.rm(part)
    end
  end

  defp args(reference, existing, part) do
    %{"url" => reference.uri}
    |> put_present("fragment", reference.fragment)
    |> put_present("reference_validator", existing && existing.reference_validator)
    |> put_present("cache_path", part)
  end

  # The reference is read again once the run is over: an answer for a target it
  # no longer names — moved or removed while the run was in flight — is not
  # kept, so no entry ever holds one target's content under another's name.
  defp still_named({:error, _reason} = refusal, _reference), do: refusal

  defp still_named(result, reference) do
    case Repo.get(Reference, reference.id) do
      %Reference{uri: uri, fragment: fragment}
      when uri == reference.uri and fragment == reference.fragment ->
        result

      _moved_or_gone ->
        {:error, changed(reference)}
    end
  end

  defp keep({:ok, %{"unchanged" => true}}, reference, _recipe, %CacheEntry{} = existing, _part) do
    existing
    |> CacheEntry.changeset(%{checked_at: now()})
    |> Repo.update(stale_error_field: :id)
    |> case do
      {:ok, entry} -> {:ok, %{outcome: "unchanged", entry: entry}}
      {:error, _dropped_meanwhile} -> {:error, changed(reference)}
    end
  end

  defp keep({:ok, %{"unchanged" => true}}, _reference, recipe, nil, _part),
    do: {:error, contract(recipe, "it answered unchanged with nothing of its own cached to keep")}

  defp keep({:ok, answer}, reference, recipe, _existing, part) when is_map(answer) do
    with {:ok, format} <- format(answer, recipe),
         {:ok, validator} <- validator(answer, recipe),
         {:ok, content} <- content(answer, recipe, reference, format, part),
         {:ok, entry} <- store(reference, recipe, format, validator, content) do
      {:ok, %{outcome: "fetched", entry: entry}}
    end
  end

  defp keep({:ok, _answer}, _reference, recipe, _existing, _part),
    do: {:error, predates(recipe)}

  defp keep({:error, _reason} = refusal, _reference, _recipe, _existing, _part), do: refusal

  defp format(answer, recipe) do
    case Map.get(answer, "format", "text/markdown") do
      format when is_binary(format) ->
        if String.contains?(format, "/"), do: {:ok, format}, else: {:error, bad_format(recipe)}

      _other ->
        {:error, bad_format(recipe)}
    end
  end

  defp validator(answer, recipe) do
    case Map.get(answer, "reference_validator") do
      validator when is_binary(validator) or is_nil(validator) -> {:ok, validator}
      _other -> {:error, contract(recipe, "reference_validator must be a string")}
    end
  end

  defp content(%{"content" => text}, %{cache: "text"} = recipe, _reference, format, _part) do
    cond do
      not is_binary(text) -> {:error, contract(recipe, "content must be a string")}
      not String.starts_with?(format, "text/") -> {:error, not_text_format(recipe, format)}
      byte_size(text) > @text_limit -> {:error, too_long(recipe, text)}
      String.contains?(text, <<0>>) -> {:error, not_text(recipe)}
      true -> {:ok, %{body: text, path: nil, size_bytes: byte_size(text)}}
    end
  end

  defp content(_answer, %{cache: "file"} = recipe, reference, format, part) do
    if File.regular?(part) do
      name = "#{reference.id}.#{Map.get(@extensions, format, "bin")}"
      File.rename!(part, Path.join(dir(), name))
      {:ok, %{body: nil, path: name, size_bytes: File.stat!(Path.join(dir(), name)).size}}
    else
      {:error, contract(recipe, "it stores files and wrote nothing at cache_path")}
    end
  end

  defp content(_answer, recipe, _reference, _format, _part), do: {:error, predates(recipe)}

  # One cache entry per reference: a refetch replaces the row in place,
  # whichever of two concurrent refreshes lands last. A row that cannot be
  # written takes its new file with it, so no file holds bytes its row does not
  # describe; a row it replaced that named the same file is then a miss.
  defp store(reference, recipe, format, validator, content) do
    stamp = now()

    attrs =
      Map.merge(content, %{
        reference_id: reference.id,
        uri: reference.uri,
        fragment: reference.fragment,
        script: recipe.script,
        format: format,
        reference_validator: validator,
        fetched_at: stamp,
        checked_at: stamp
      })

    case insert(attrs) do
      {:ok, entry} ->
        {:ok, entry}

      :reference_gone ->
        remove_file(content.path)
        {:error, changed(reference)}
    end
  end

  # SQLite names no foreign key it refuses, so a reference removed after the
  # run's check arrives as this raise rather than as a changeset error.
  defp insert(attrs) do
    %CacheEntry{}
    |> CacheEntry.changeset(attrs)
    |> Repo.insert!(
      on_conflict: {:replace_all_except, [:id, :reference_id, :inserted_at]},
      conflict_target: :reference_id,
      returning: [:id, :inserted_at]
    )
    |> then(&{:ok, &1})
  rescue
    error in Ecto.ConstraintError ->
      if error.type == :foreign_key, do: :reference_gone, else: reraise(error, __STACKTRACE__)
  end

  # A refetch that replaced another script's row, or another format's, leaves
  # no file the new row does not name.
  defp tidy_previous({:ok, %{entry: %CacheEntry{path: kept}}} = result, %CacheEntry{path: old})
       when is_binary(old) and old != kept do
    remove_file(old)
    result
  end

  defp tidy_previous(result, _previous), do: result

  # ─── Serving ────────────────────────────────────────────────────────

  defp served(%CacheEntry{format: "text/" <> _subtype} = entry, fetched?, options) do
    case text(entry) do
      {:ok, text} -> answer(entry, fetched?, {:text, Window.take(text, options)})
      :error -> answer(entry, fetched?, {:described, not_text_note()})
    end
  end

  defp served(%CacheEntry{format: format, path: path} = entry, fetched?, _options)
       when format in @served_images and is_binary(path) do
    file = full_path(path)

    if base64_size(File.stat!(file).size) <= @image_limit,
      do: answer(entry, fetched?, {:image, file |> File.read!() |> Base.encode64(), format}),
      else: answer(entry, fetched?, {:described, too_large_note()})
  end

  defp served(entry, fetched?, _options),
    do: answer(entry, fetched?, {:described, format_note(entry)})

  defp answer(entry, fetched?, served), do: %{entry: entry, fetched: fetched?, served: served}

  defp text(%CacheEntry{body: body}) when is_binary(body), do: {:ok, body}

  defp text(%CacheEntry{path: path}) do
    text = path |> full_path() |> File.read!()
    if String.valid?(text) and not String.contains?(text, <<0>>), do: {:ok, text}, else: :error
  end

  # ─── Helpers ────────────────────────────────────────────────────────

  # A reference no script fetches any more keeps no entry.
  defp with_recipe(reference, declarations, fun) do
    case recipe(reference, declarations) do
      {:ok, recipe} ->
        fun.(recipe)

      {:error, _no_recipe} = refusal ->
        drop(reference.id)
        refusal
    end
  end

  defp stored(reference), do: Repo.get_by(CacheEntry, reference_id: reference.id)

  # The entry the recipe's script filled for the target the reference names
  # now, its file in place — or nil: another script's entry, another target's,
  # or one whose file is gone is a miss.
  defp current(nil, _reference, _recipe), do: nil

  defp current(%CacheEntry{} = entry, reference, recipe) do
    if entry.script == recipe.script and entry.uri == reference.uri and
         entry.fragment == reference.fragment and file_present?(entry),
       do: entry
  end

  defp file_present?(%CacheEntry{path: nil}), do: true
  defp file_present?(%CacheEntry{path: path}), do: File.regular?(full_path(path))

  defp put_present(map, _key, value) when value in [nil, ""], do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp part_path(reference_id) do
    File.mkdir_p!(dir())
    Path.join(dir(), "#{reference_id}.part-#{System.unique_integer([:positive])}")
  end

  defp full_path(name), do: Path.join(dir(), name)

  defp base64_size(bytes), do: div(bytes + 2, 3) * 4

  defp remove_file(nil), do: :ok

  defp remove_file(name) do
    File.rm(full_path(name))
    :ok
  end

  defp nodes_own?(name), do: Regex.match?(@entry_file, name) or Regex.match?(@part_file, name)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  # ─── Refusals ───────────────────────────────────────────────────────

  defp predates(recipe) do
    {:not_cache_contract,
     "#{recipe.script} #{recipe.action} answered neither `content` nor `unchanged` — the " <>
       "script predates the cache contract"}
  end

  defp contract(recipe, rule),
    do: {:not_cache_contract, "#{recipe.script} #{recipe.action}: #{rule}"}

  defp bad_format(recipe),
    do: contract(recipe, "format must be a media type such as text/markdown")

  defp not_text_format(recipe, format) do
    contract(
      recipe,
      "it stores text, so it answers a text/* format — #{format} is converted to text " <>
        "first, or kept by a script that stores files (cache: :file)"
    )
  end

  defp too_long(recipe, text) do
    contract(
      recipe,
      "its content is #{byte_size(text)} bytes, over the #{@text_limit} the cache keeps as text"
    )
  end

  defp changed(reference) do
    {:reference_changed,
     "reference ##{reference.id} was changed or removed while its fetch was running — the " <>
       "answer for #{reference.uri} is not kept"}
  end

  defp not_text(recipe) do
    {:not_text,
     "#{recipe.script} #{recipe.action} answered text with a NUL byte — the cache keeps text " <>
       "only, so the entry that was there stands"}
  end

  defp not_text_note,
    do: "stored as a file whose bytes are not text, though its format says text"

  defp too_large_note,
    do: "larger than the #{@image_limit} base64 bytes an image is served at"

  # Only a file reaches here: a body is always text, served by its own clause.
  defp format_note(%CacheEntry{}) do
    "not a format a model reads as it stands — a script meant for one converts it " <>
      "(a spreadsheet to csv, a pdf to text or page images); the path needs file access"
  end
end
