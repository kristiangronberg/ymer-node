defmodule YmerNode.References.CacheTest do
  @moduledoc """
  Every case creates the scripts it fetches through `YmerNode.Scripts`,
  so the sandbox owns their rows and the module is not async; each fixture
  takes a module name unique to its case and purges its own tree.

  Two fixture scripts stand in for every kind a recipe can name: one storing
  text, claiming `text.example.test`, and one storing files, claiming
  `files.example.test`. What each answers is decided by the url's path, and the
  text one writes the arguments it was handed into its page, so a case reads
  what the node passed from what it stored. Neither reaches the network.

  The cache directory is the partitioned test one; cases write files named
  for their own references and remove them on exit.
  """
  use YmerNode.DataCase

  import ExUnit.CaptureLog

  alias YmerNode.References
  alias YmerNode.References.{Cache, CacheEntry, Sources}
  alias YmerNode.References.Cache.Reconcile
  alias YmerNode.Scripts
  alias YmerNode.Scripts.Compiler

  setup do
    text = script!("text.example.test", ":text", text_body())
    files = script!("files.example.test", ":file", files_body())

    on_exit(fn ->
      for name <- File.ls!(Cache.dir()), do: File.rm(Path.join(Cache.dir(), name))
    end)

    File.mkdir_p!(Cache.dir())

    %{text: text, files: files}
  end

  describe "read/3 — text" do
    test "fetches once on a miss, then serves the entry without running the script" do
      reference = reference!("https://text.example.test/page")

      assert {:ok, %{fetched: true, served: {:text, window}, entry: entry}} = read(reference)
      assert window.text =~ "# Page"
      assert %{total_lines: 2, next: nil} = window
      assert entry.format == "text/markdown"
      assert entry.reference_validator == "v1"

      assert {:ok, %{fetched: false, served: {:text, again}}} = read(reference)
      assert again.text == window.text
    end

    test "hands the script the reference's fragment, and no validator on a first fetch" do
      reference = reference!("https://text.example.test/page", "Intro")

      assert {:ok, %{served: {:text, window}}} = read(reference)
      assert window.text =~ ~s(fragment=Intro)
      assert window.text =~ ~s(validator=none)
    end

    test "serves the window the options name" do
      reference = reference!("https://text.example.test/page")

      assert {:ok, %{served: {:text, window}}} = read(reference, offset: 2, limit: 1)
      assert %{offset: 2, lines: 1, total_lines: 2} = window
      refute window.text =~ "# Page"
    end

    @tag doc: """
         A validator means something only to the script that issued it. A
         failure means an entry another script filled is served as current, or
         its validator is handed to a script that cannot read it.
         """
    test "treats an entry another script filled as a miss, refetched with no validator", %{
      text: text
    } do
      reference = reference!("https://text.example.test/page")
      insert_entry!(reference, script: "somebody_else", body: "stale", reference_validator: "v1")

      assert {:ok, %{fetched: true, served: {:text, window}, entry: entry}} = read(reference)
      assert window.text =~ "validator=none"
      assert entry.script == text.name
    end

    @tag doc: """
         A cache entry answers for the target it was fetched for. A failure
         means an entry fetched before the reference moved is served as the
         page the reference names now.
         """
    test "treats an entry fetched for another target as a miss", %{text: text} do
      reference = reference!("https://text.example.test/page")

      insert_entry!(reference,
        script: text.name,
        body: "the old page",
        uri: "https://text.example.test/old"
      )

      assert {:ok, %{fetched: true, served: {:text, window}, entry: entry}} = read(reference)
      assert window.text =~ "# Page"
      assert entry.uri == reference.uri
    end

    test "keeps a page that renders to nothing as an empty entry" do
      assert {:ok, %{served: {:text, empty}, entry: %{body: ""}}} =
               read(reference!("https://text.example.test/empty"))

      assert %{text: "", total_lines: 0, next: nil} = empty

      assert {:ok, %{served: {:text, blank}, entry: %{body: "\n"}}} =
               read(reference!("https://text.example.test/blank"))

      assert %{total_lines: 1, next: nil} = blank
    end

    test "refuses a reference no script fetches, drops its entry, and names the pointer" do
      reference = reference!("https://nobody.example.test/page")
      insert_entry!(reference, script: "gone", body: "orphan")

      assert {:error, {:no_recipe, detail}} = read(reference)
      assert detail =~ "no script fetches https://nobody.example.test/page"
      assert detail =~ "a pointer only"
      assert Repo.aggregate(CacheEntry, :count) == 0
    end
  end

  describe "refresh/2" do
    test "hands the stored validator back, and keeps the entry when the script answers unchanged" do
      reference = reference!("https://text.example.test/same")

      assert {:ok, %{outcome: "fetched", entry: first}} = refresh(reference)
      backdate!(first)

      assert {:ok, %{outcome: "unchanged", entry: kept}} = refresh(reference)
      assert kept.body == first.body
      assert kept.fetched_at == ~U[2026-01-01 00:00:00Z]
      assert DateTime.compare(kept.checked_at, kept.fetched_at) == :gt
    end

    @tag doc: """
         Every refusal keeps the entry that was there: a cache that dropped its
         page because the script failed once would serve nothing where it could
         serve what it had, stamped with its age.
         """
    test "keeps the entry when the script fails, its error passed through" do
      reference = reference!("https://text.example.test/page")
      assert {:ok, %{entry: entry}} = refresh(reference)

      # The uri is moved in the row itself, beneath the context — this case is
      # about the script failing, not about a uri change dropping the entry.
      Repo.update_all(from(r in References.Reference, where: r.id == ^reference.id),
        set: [uri: "https://text.example.test/fails"]
      )

      failing = Repo.get!(References.Reference, reference.id)

      assert {:error, {:script_error, detail}} = refresh(failing)
      assert detail =~ "boom"
      assert Repo.get_by!(CacheEntry, reference_id: reference.id).body == entry.body
    end

    test "refuses text carrying a NUL byte, keeping nothing" do
      reference = reference!("https://text.example.test/nul")

      assert {:error, {:not_text, detail}} = refresh(reference)
      assert detail =~ "NUL byte"
      assert Repo.aggregate(CacheEntry, :count) == 0
    end

    @tag doc: """
         A URL action written before the cache contract answers whatever it
         answered — a summary map, a body under another key. A failure means
         such an answer is cached as the page, which is the note or the shape
         that script happened to return rather than what the target says.
         """
    test "refuses an answer with neither content nor unchanged as predating the contract" do
      reference = reference!("https://text.example.test/legacy")

      assert {:error, {:not_cache_contract, detail}} = refresh(reference)
      assert detail =~ "predates the cache contract"
    end

    test "refuses a format that is not a media type, and unchanged with nothing to keep" do
      assert {:error, {:not_cache_contract, format}} =
               refresh(reference!("https://text.example.test/bad-format"))

      assert format =~ "format must be a media type"

      assert {:error, {:not_cache_contract, unchanged}} =
               refresh(reference!("https://text.example.test/unchanged"))

      assert unchanged =~ "nothing of its own cached to keep"
    end

    @tag doc: """
         A text entry is only ever served as text, so a text-storing script
         answers a text format. A failure means an entry the tool can never
         serve: stored, stamped, and answered only with a description.
         """
    test "refuses a text-storing script's answer in a format that is not text" do
      assert {:error, {:not_cache_contract, detail}} =
               refresh(reference!("https://text.example.test/json"))

      assert detail =~ "answers a text/* format"
      assert detail =~ "cache: :file"
      assert Repo.aggregate(CacheEntry, :count) == 0
    end

    test "refuses text over the text limit" do
      assert {:error, {:not_cache_contract, detail}} =
               refresh(reference!("https://text.example.test/long"))

      assert detail =~ "over the #{Cache.text_limit()} the cache keeps as text"
      assert Repo.aggregate(CacheEntry, :count) == 0
    end

    @tag doc: """
         The reference is read again once the run is over. A failure means an
         answer for the target a reference named when the run began is kept
         under the target it names now — the page before a move, served as the
         page after it.
         """
    test "keeps nothing when the reference moved while the run was in flight" do
      reference = reference!("https://text.example.test/page")

      # The row moves beneath the context while `reference` is the value the
      # run started from — the state a slow fetch finishes into.
      Repo.update_all(from(r in References.Reference, where: r.id == ^reference.id),
        set: [uri: "https://text.example.test/moved"]
      )

      assert {:error, {:reference_changed, detail}} = refresh(reference)
      assert detail =~ "reference ##{reference.id} was changed or removed"
      assert Repo.aggregate(CacheEntry, :count) == 0
    end

    test "keeps nothing, and leaves no file, when the reference went while the run was in flight" do
      reference = reference!("https://files.example.test/image")
      Repo.delete_all(from(r in References.Reference, where: r.id == ^reference.id))

      assert {:error, {:reference_changed, _detail}} = refresh(reference)
      assert Repo.aggregate(CacheEntry, :count) == 0
      assert File.ls!(Cache.dir()) == []
    end
  end

  describe "files" do
    test "keeps what a file-storing script wrote, named for the reference, and serves an image" do
      reference = reference!("https://files.example.test/image")

      assert {:ok, %{served: {:image, data, "image/png"}, entry: entry}} = read(reference)
      assert Base.decode64!(data) == png()
      assert entry.path == "#{reference.id}.png"
      assert entry.body == nil
      assert File.read!(Path.join(Cache.dir(), entry.path)) == png()
      assert Cache.dir() |> File.ls!() |> Enum.filter(&String.contains?(&1, ".part-")) == []
    end

    test "serves a text file by line window" do
      reference = reference!("https://files.example.test/notes")

      assert {:ok, %{served: {:text, %{text: "plain notes\n"}}}} = read(reference)
    end

    test "describes a format a model cannot read, with its path and size" do
      reference = reference!("https://files.example.test/doc")

      assert {:ok, %{served: {:described, note}, entry: entry}} = read(reference)
      assert note =~ "a script meant for one converts it"
      assert entry.path == "#{reference.id}.bin"
      assert entry.size_bytes == 4
    end

    test "describes an image larger than the limit rather than serving it" do
      reference = reference!("https://files.example.test/huge")

      assert {:ok, %{served: {:described, note}}} = read(reference)
      assert note =~ "#{Cache.image_limit()} base64 bytes"
    end

    test "refuses a file-storing script that wrote nothing, leaving no part file" do
      reference = reference!("https://files.example.test/nothing")

      assert {:error, {:not_cache_contract, detail}} = refresh(reference)
      assert detail =~ "wrote nothing at cache_path"
      assert File.ls!(Cache.dir()) == []
    end

    @tag doc: """
         The cache directory follows the node database, and a file can still
         go on its own — by hand, or with a volume. A failure means a read of
         that reference raises for as long as the entry stands.
         """
    test "an entry whose file is gone is a miss, fetched and written again" do
      reference = reference!("https://files.example.test/image")
      assert {:ok, %{entry: entry}} = refresh(reference)
      file = Path.join(Cache.dir(), entry.path)

      File.rm!(file)
      assert {:ok, %{fetched: true, served: {:image, _data, "image/png"}}} = read(reference)
      assert File.read!(file) == png()

      File.rm!(file)
      assert {:ok, %{outcome: "fetched"}} = refresh(reference)
      assert File.exists?(file)

      File.rm_rf!(Cache.dir())
      assert {:ok, %{fetched: true}} = read(reference)
      assert File.exists?(file)
    end

    test "a refetch in another format removes the file the old entry named", %{files: files} do
      reference = reference!("https://files.example.test/photo")
      old = "#{reference.id}.png"
      File.write!(Path.join(Cache.dir(), old), png())
      insert_entry!(reference, script: files.name, format: "image/png", path: old)

      assert {:ok, %{outcome: "fetched", entry: entry}} = refresh(reference)
      assert entry.path == "#{reference.id}.jpg"
      assert File.ls!(Cache.dir()) == [entry.path]
    end

    @tag doc: """
         An entry another script filled is replaced whole, its file included.
         A failure means the file the old entry named stays in the cache
         directory, named by no entry, until the next boot.
         """
    test "a refetch by another script removes the file the old entry named" do
      reference = reference!("https://text.example.test/page")
      old = "#{reference.id}.docx"
      File.write!(Path.join(Cache.dir(), old), "DOCX")
      insert_entry!(reference, script: "somebody_else", format: "application/msword", path: old)

      assert {:ok, %{fetched: true, entry: entry}} = read(reference)
      assert entry.path == nil
      assert File.ls!(Cache.dir()) == []
    end
  end

  describe "drop/1" do
    test "removes the entry and its file" do
      reference = reference!("https://files.example.test/image")
      assert {:ok, %{entry: entry}} = refresh(reference)

      assert :ok = Cache.drop(reference.id)
      assert Repo.aggregate(CacheEntry, :count) == 0
      refute File.exists?(Path.join(Cache.dir(), entry.path))
      assert :ok = Cache.drop(reference.id)
    end
  end

  describe "reconcile/0" do
    @tag doc: """
         The boot step that makes the directory rebuildable with the node
         database. A failure that leaves the unnamed files means a fresh node
         database keeps serving nothing from a directory full of orphans; one
         that removes `notes.txt` means the reconcile deletes what the node
         never wrote.
         """
    test "removes the node's unnamed files and the part files, and nothing else" do
      reference = reference!("https://files.example.test/image")
      assert {:ok, %{entry: entry}} = refresh(reference)

      for name <- ["999999.png", "999999.part-1", "notes.txt", "999998"],
          do: File.write!(Path.join(Cache.dir(), name), "x")

      assert Cache.reconcile() == ["999999.part-1", "999999.png"]
      assert Enum.sort(File.ls!(Cache.dir())) == Enum.sort([entry.path, "notes.txt", "999998"])
    end

    test "deletes an entry whose file is gone" do
      reference = reference!("https://files.example.test/image")
      assert {:ok, %{entry: entry}} = refresh(reference)
      File.rm!(Path.join(Cache.dir(), entry.path))

      assert Cache.reconcile() == []
      assert Repo.aggregate(CacheEntry, :count) == 0
    end
  end

  describe "the boot reconcile" do
    @tag doc: """
         The cache is rebuildable and the notebook and the registry are not.
         A failure means a cache directory the node cannot use — a mount gone
         read-only, a file where the directory should be — keeps the whole
         node from booting.
         """
    test "logs a reconcile that fails, and lets the boot go on" do
      saved = {Application.get_env(:ymer_node, Cache), Application.get_env(:ymer_node, Reconcile)}

      not_a_directory =
        Path.join(System.tmp_dir!(), "cache-#{System.unique_integer([:positive])}")

      File.write!(not_a_directory, "a file where the cache directory should be")

      on_exit(fn ->
        {cache, reconcile} = saved
        Application.put_env(:ymer_node, Cache, cache)
        Application.put_env(:ymer_node, Reconcile, reconcile)
        File.rm(not_a_directory)
      end)

      Application.put_env(:ymer_node, Cache, dir: not_a_directory)
      Application.put_env(:ymer_node, Reconcile, enabled: true)

      log = capture_log(fn -> assert Reconcile.start_link() == :ignore end)
      assert log =~ "cache: could not reconcile the cache directory"
    end
  end

  # ─── Fixtures ───────────────────────────────────────────────────────

  defp read(reference, options \\ []), do: Cache.read(reference, Sources.declarations(), options)
  defp refresh(reference), do: Cache.refresh(reference, Sources.declarations())

  defp reference!(uri, fragment \\ "") do
    {:ok, reference} =
      References.create_reference(%{title: "A page", uri: uri, fragment: fragment})

    reference
  end

  defp insert_entry!(reference, fields) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs =
      Map.merge(
        %{
          reference_id: reference.id,
          uri: reference.uri,
          fragment: reference.fragment,
          format: "text/markdown",
          size_bytes: 1,
          fetched_at: now,
          checked_at: now
        },
        Map.new(fields)
      )

    %CacheEntry{} |> CacheEntry.changeset(attrs) |> Repo.insert!()
  end

  defp backdate!(entry) do
    Repo.update_all(from(e in CacheEntry, where: e.id == ^entry.id),
      set: [fetched_at: ~U[2026-01-01 00:00:00Z], checked_at: ~U[2026-01-01 00:00:00Z]]
    )
  end

  defp png, do: <<137, 80, 78, 71, 13, 10, 26, 10>>

  defp script!(host, mode, body) do
    segment =
      "Cache#{String.capitalize(String.trim_leading(mode, ":"))}#{System.unique_integer([:positive])}"

    on_exit(fn -> Compiler.purge(Module.concat(["Script", segment])) end)

    code = """
    defmodule Script.#{segment} do
      use YmerNode.Script

      @impl true
      def description, do: "answers #{host} pages for the cache"

      @impl true
      def actions do
        %{
          fetch: %{
            description: "one page",
            properties: %{"url" => %{"type" => "string"}},
            required: ["url"],
            write: false
          }
        }
      end

      @impl true
      def declarations, do: %{hosts: ["#{host}"], url_action: :fetch, secrets: [], cache: #{mode}}

      @impl true
      def run(:fetch, %{"url" => url} = args, _context), do: answer(URI.parse(url).path, args)

    #{body}
    end
    """

    assert {:ok, script} = Scripts.create(code)
    script
  end

  defp text_body do
    ~S"""
      defp answer("/page", args) do
        {:ok,
         %{
           "content" =>
             "# Page\nfragment=#{args["fragment"]} validator=#{args["reference_validator"] || "none"}\n",
           "format" => "text/markdown",
           "reference_validator" => "v1"
         }}
      end

      defp answer("/same", %{"reference_validator" => "v1"}), do: {:ok, %{"unchanged" => true}}

      defp answer("/same", _args),
        do: {:ok, %{"content" => "# Same\n", "reference_validator" => "v1"}}

      defp answer("/nul", _args), do: {:ok, %{"content" => "a\0b"}}
      defp answer("/legacy", _args), do: {:ok, %{"body" => "the old shape"}}
      defp answer("/bad-format", _args), do: {:ok, %{"content" => "x", "format" => "markdown"}}
      defp answer("/unchanged", _args), do: {:ok, %{"unchanged" => true}}
      defp answer("/fails", _args), do: {:error, "boom"}
      defp answer("/json", _args), do: {:ok, %{"content" => "{}", "format" => "application/json"}}
      defp answer("/empty", _args), do: {:ok, %{"content" => ""}}
      defp answer("/blank", _args), do: {:ok, %{"content" => "\n"}}
      defp answer("/long", _args), do: {:ok, %{"content" => String.duplicate("x", 5_000_001)}}
    """
  end

  defp files_body do
    ~S"""
      defp answer("/image", args), do: write(args, <<137, 80, 78, 71, 13, 10, 26, 10>>, "image/png")
      defp answer("/photo", args), do: write(args, <<255, 216, 255, 224>>, "image/jpeg")
      defp answer("/notes", args), do: write(args, "plain notes\n", "text/plain")
      defp answer("/doc", args), do: write(args, "DOCX", "application/vnd.ms-word")
      defp answer("/huge", args), do: write(args, :binary.copy("x", 3_700_000), "image/png")
      defp answer("/nothing", _args), do: {:ok, %{"format" => "image/png"}}

      defp write(%{"cache_path" => path}, bytes, format) do
        File.write!(path, bytes)
        {:ok, %{"format" => format}}
      end
    """
  end
end
