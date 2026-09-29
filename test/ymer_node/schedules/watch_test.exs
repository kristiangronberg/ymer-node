defmodule YmerNode.Schedules.WatchTest do
  @moduledoc """
  Watches through `YmerNode.Schedules`, beside `YmerNode.SchedulesTest`'s
  schedules of a script: the case creates the one script a watch's firing
  runs through `YmerNode.Scripts`, so the sandbox owns it and the module is not
  async. The script claims `watch.example.test` and answers a page naming the
  url it was handed, which is how a case sees which target a firing fetched.
  `fire/2` is called in the case's own process, as in `YmerNode.SchedulesTest`.
  """
  use YmerNode.DataCase

  alias YmerNode.References
  alias YmerNode.References.{Cache, CacheEntry}
  alias YmerNode.Schedules
  alias YmerNode.Schedules.Schedule
  alias YmerNode.Scripts
  alias YmerNode.Scripts.Compiler

  describe "watch/3" do
    test "starts a watch named for the reference, at its cadence, for its lifetime" do
      reference = reference!("https://watch.example.test/page")

      before = DateTime.utc_now()
      assert {:ok, entry} = Schedules.watch(reference, 15, 2)
      after_write = DateTime.utc_now()

      assert %{name: name, watch: %{reference: id}, cron_expression: "*/15 * * * *"} = entry
      assert name == "reference-#{reference.id}"
      assert id == reference.id
      refute Map.has_key?(entry, :script)
      assert_lifetime(entry.ends_at, 2, before, after_write)
    end

    test "refuses a reference removed before the watch is written" do
      reference = reference!("https://watch.example.test/page")
      assert {:ok, _deleted} = References.delete_reference(reference)

      assert {:error, {:not_found, _detail}} = Schedules.watch(reference, 15, 1)
    end

    test "maps each cadence to its cron expression" do
      reference = reference!("https://watch.example.test/page")

      for {minutes, expression} <- [
            {5, "*/5 * * * *"},
            {30, "*/30 * * * *"},
            {60, "0 * * * *"}
          ] do
        assert {:ok, %{cron_expression: ^expression}} = Schedules.watch(reference, minutes, 1)
      end
    end

    @tag doc: """
         One watch per reference, and starting one again is how its cadence
         and lifetime change. A failure means a second row, which the unique
         index then refuses as an error instead of a replace.
         """
    test "watching again replaces the cadence and the lifetime, keeping one row" do
      reference = reference!("https://watch.example.test/page")
      {:ok, _first} = Schedules.watch(reference, 60, 1)

      before = DateTime.utc_now()
      assert {:ok, again} = Schedules.watch(reference, 5, 12)
      after_write = DateTime.utc_now()

      assert again.cron_expression == "*/5 * * * *"
      assert_lifetime(again.ends_at, 12, before, after_write)
      assert Repo.aggregate(Schedule, :count) == 1
    end

    test "refuses a cadence or a lifetime outside the watch's bounds" do
      reference = reference!("https://watch.example.test/page")

      assert {:error, {:invalid_cadence, detail}} = Schedules.watch(reference, 10, 1)
      assert detail =~ "5, 15, 30 or 60"

      for hours <- [0, 13] do
        assert {:error, {:invalid_lifetime, detail}} = Schedules.watch(reference, 5, hours)
        assert detail =~ "1 to 12"
      end

      assert Schedules.list() == []
    end
  end

  describe "unwatch/1" do
    test "stops the watch, and refuses a reference that has none" do
      reference = reference!("https://watch.example.test/page")
      {:ok, _watch} = Schedules.watch(reference, 15, 1)

      assert {:ok, %Schedule{}} = Schedules.unwatch(reference.id)
      assert Schedules.list() == []

      assert {:error, {:not_found, "reference " <> _rest}} = Schedules.unwatch(reference.id)
    end
  end

  describe "a watch among the schedules" do
    test "add refuses a name in the watches' prefix" do
      script = script!()

      assert {:error, {:reserved_name, detail}} =
               Schedules.add(%{
                 name: "reference-7",
                 script: script.name,
                 action: "fetch",
                 args: %{"url" => "https://watch.example.test/"},
                 cron_expression: "0 7 * * *"
               })

      assert detail =~ "watches the references tool starts"
    end

    test "update refuses a watch, naming the references action; remove stops it" do
      reference = reference!("https://watch.example.test/page")
      {:ok, %{name: name}} = Schedules.watch(reference, 15, 1)

      assert {:error, {:watch, detail}} = Schedules.update(name, %{cron_expression: "* * * * *"})
      assert detail =~ "references watch"

      assert {:ok, _removed} = Schedules.remove(name)
      assert Schedules.list() == []
    end

    test "goes with its reference, and stays when a script is removed" do
      script = script!()
      reference = reference!("https://watch.example.test/page")
      {:ok, _watch} = Schedules.watch(reference, 15, 1)

      assert {:ok, _removed} = Scripts.remove(script.name)
      assert [%{watch: %{reference: _id}}] = Schedules.list()

      assert {:ok, _deleted} = References.delete_reference(reference)
      assert Schedules.list() == []
    end
  end

  describe "fire/2 of a watch" do
    test "refreshes the reference's cache entry through the recipe's script" do
      script = script!()
      reference = reference!("https://watch.example.test/page")
      {:ok, %{name: name}} = Schedules.watch(reference, 15, 1)

      assert Schedules.fire(active!(name), ~U[2026-09-29 07:00:00Z]) == "ok"

      assert %CacheEntry{script: fetched_by, body: body} =
               Repo.get_by!(CacheEntry, reference_id: reference.id)

      assert fetched_by == script.name
      assert body =~ "https://watch.example.test/page"
      assert [%{last_run: %{outcome: "ok"}}] = Schedules.list()
    end

    @tag doc: """
         A firing looks the reference up rather than carrying a url, so a
         changed uri is followed at the next firing. A failure means the watch
         froze its first target and keeps refreshing a page the reference no
         longer names.
         """
    test "follows a changed uri at the next firing" do
      script!()
      reference = reference!("https://watch.example.test/page")
      {:ok, %{name: name}} = Schedules.watch(reference, 15, 1)

      {:ok, _moved} =
        References.update_reference(reference, %{uri: "https://watch.example.test/moved"})

      assert Schedules.fire(active!(name), ~U[2026-09-29 07:00:00Z]) == "ok"
      assert Repo.get_by!(CacheEntry, reference_id: reference.id).body =~ "/moved"
    end

    @tag doc: """
         Every firing records an outcome, a raise around the run included. A
         failure means a watch that fails at every firing — a full disk, a
         cache directory it cannot write — keeps showing its last good run.
         """
    test "records error when its refresh raises around the run" do
      script!(":file")
      reference = reference!("https://watch.example.test/page")
      {:ok, %{name: name}} = Schedules.watch(reference, 15, 1)

      saved = Application.get_env(:ymer_node, Cache)

      not_a_directory =
        Path.join(System.tmp_dir!(), "watch-#{System.unique_integer([:positive])}")

      File.write!(not_a_directory, "a file where the cache directory should be")
      Application.put_env(:ymer_node, Cache, dir: not_a_directory)

      on_exit(fn ->
        Application.put_env(:ymer_node, Cache, saved)
        File.rm(not_a_directory)
      end)

      assert Schedules.fire(active!(name), ~U[2026-09-29 07:00:00Z]) == "error"
      assert [%{last_run: %{outcome: "error", message: message}}] = Schedules.list()
      assert message =~ name
    end

    test "records refused, and keeps its lifetime, when no script fetches the reference" do
      reference = reference!("https://nobody.example.test/page")
      {:ok, %{name: name, ends_at: ends_at}} = Schedules.watch(reference, 15, 1)

      assert Schedules.fire(active!(name), ~U[2026-09-29 07:00:00Z]) == "refused"

      assert [%{state: "active", ends_at: ^ends_at, last_run: last_run}] = Schedules.list()
      assert %{outcome: "refused", message: "no script fetches " <> _rest} = last_run
    end

    test "drops the entry of a reference no script fetches any more" do
      script = script!()
      reference = reference!("https://watch.example.test/page")
      {:ok, %{name: name}} = Schedules.watch(reference, 15, 1)
      assert Schedules.fire(active!(name), ~U[2026-09-29 07:00:00Z]) == "ok"
      assert Repo.aggregate(CacheEntry, :count) == 1

      assert {:ok, _removed} = Scripts.remove(script.name)
      assert Schedules.fire(active!(name), ~U[2026-09-29 07:15:00Z]) == "refused"
      assert Repo.aggregate(CacheEntry, :count) == 0
    end

    @tag doc: """
         What a firing does before its run — the lookups, the recipe, and the
         drop of an entry no script fetches any more — is contained as the run
         is. A failure means a raise there kills the firing and the watch keeps
         showing its last good run.
         """
    test "records error when what it does before the run raises" do
      script = script!(":file")
      reference = reference!("https://watch.example.test/page")
      {:ok, %{name: name}} = Schedules.watch(reference, 15, 1)
      assert Schedules.fire(active!(name), ~U[2026-09-29 07:00:00Z]) == "ok"
      assert {:ok, _removed} = Scripts.remove(script.name)

      saved = Application.get_env(:ymer_node, Cache)
      Application.put_env(:ymer_node, Cache, [])
      on_exit(fn -> Application.put_env(:ymer_node, Cache, saved) end)

      assert Schedules.fire(active!(name), ~U[2026-09-29 07:15:00Z]) == "error"
      assert [%{last_run: %{outcome: "error", message: message}}] = Schedules.list()
      assert message =~ name
    end
  end

  defp reference!(uri) do
    {:ok, reference} = References.create_reference(%{title: "A watched page", uri: uri})
    reference
  end

  defp active!(name), do: Enum.find(Schedules.active(DateTime.utc_now()), &(&1.name == name))

  # The end lies `hours` after the write, which happened between `before` and
  # `after_write`; the stored end is cut to the second.
  defp assert_lifetime(iso, hours, before, after_write) do
    {:ok, at, _offset} = DateTime.from_iso8601(iso)

    assert DateTime.compare(at, DateTime.add(before, hours * 3600 - 1)) != :lt
    assert DateTime.compare(at, DateTime.add(after_write, hours * 3600)) != :gt
  end

  defp script!(mode \\ ":text") do
    segment = "Watched#{System.unique_integer([:positive])}"
    on_exit(fn -> Compiler.purge(Module.concat(["Script", segment])) end)

    code = """
    defmodule Script.#{segment} do
      use YmerNode.Script

      @impl true
      def description, do: "answers watch.example.test pages"

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
      def declarations,
        do: %{hosts: ["watch.example.test"], url_action: :fetch, secrets: [], cache: #{mode}}

      @impl true
      def run(:fetch, %{"url" => url, "cache_path" => path}, _context) do
        File.write!(path, "# Page at \#{url}\\n")
        {:ok, %{"format" => "text/markdown"}}
      end

      def run(:fetch, %{"url" => url}, _context), do: {:ok, %{"content" => "# Page at \#{url}\\n"}}
    end
    """

    assert {:ok, script} = Scripts.create(code)
    script
  end
end
