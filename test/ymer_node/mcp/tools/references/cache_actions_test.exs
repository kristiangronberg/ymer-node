defmodule YmerNode.Mcp.Tools.References.CacheActionsTest do
  @moduledoc """
  The `references` tool's cache actions — `read`, `refresh`, `watch` and
  `unwatch` — end-to-end through the repo and a fixture script, so
  `YmerNode.DataCase` and no async flag. One fixture claims `tool.example.test`,
  stores files, and answers by the url's path — a page as text or a PNG; the
  other claims `legacy.example.test` and answers the way a URL action written
  before the cache does, a summary map. Nothing reaches the network.

  The image clause is exercised through the tool module's own `run/2`, the way
  the MCP mount calls it; every other case calls the action layer.
  """
  use YmerNode.DataCase

  alias YmerNode.Mcp.Tools.References, as: Tool
  alias YmerNode.Mcp.Tools.References.Actions
  alias YmerNode.References
  alias YmerNode.References.Cache
  alias YmerNode.Schedules
  alias YmerNode.Scripts
  alias YmerNode.Scripts.Compiler

  setup do
    script!()
    legacy_script!()
    File.mkdir_p!(Cache.dir())

    on_exit(fn ->
      for name <- File.ls!(Cache.dir()), do: File.rm(Path.join(Cache.dir(), name))
    end)

    :ok
  end

  describe "read" do
    test "serves a text entry by window, with its age, fetching once" do
      reference = reference!("https://tool.example.test/page")

      assert {:ok, first, %{}} = Actions.run(:read, %{"id" => reference.id, "limit" => 1})

      assert %{fetched: true, text: "# Page\n", lines: 1, total_lines: 2, next: %{offset: 2}} =
               first

      assert %{format: "text/plain", reference: id, fetched_at: _at, checked_at: _checked} = first
      assert id == reference.id

      assert {:ok, second, %{}} = Actions.run(:read, %{"id" => reference.id, "offset" => "2"})
      assert %{fetched: false, text: "second line\n", offset: 2} = second
      refute Map.has_key?(second, :next)
    end

    test "refuses a window position that is not a positive integer" do
      reference = reference!("https://tool.example.test/page")

      for {key, value, words} <- [
            {"offset", 0, "Invalid offset"},
            {"limit", "many", "Invalid limit"},
            {"column", -1, "Invalid column"}
          ] do
        assert {:error, {reason, ctx}} = Actions.run(:read, %{"id" => reference.id, key => value})
        assert Tool.handle_error({reason, ctx}) =~ words
      end
    end

    test "names the pointer when no script fetches the reference" do
      reference = reference!("https://nobody.example.test/page")

      assert {:error, {reason, ctx}} = Actions.run(:read, %{"id" => reference.id})
      message = Tool.handle_error({reason, ctx})
      assert message =~ "no script fetches https://nobody.example.test/page"
      assert message =~ "Follow its uri yourself"
    end

    @tag doc: """
         A script written before the cache still fetches its references — as
         its recipe, run by the caller. A failure means the refusal stopped
         saying so, and a caller holding a Confluence or Jira reference is left
         with an error instead of the call that still works.
         """
    test "refuses a script that predates the cache contract, saying the recipe still works" do
      reference = reference!("https://legacy.example.test/page")

      assert {:error, {reason, ctx}} = Actions.run(:read, %{"id" => reference.id})
      message = Tool.handle_error({reason, ctx})
      assert message =~ "predates the cache contract"
      assert message =~ "its recipe still work"
    end
  end

  describe "read — the image clause" do
    @tag doc: """
         wymcp answers every action as JSON text; this clause is the one place
         an image leaves the node as image content. A failure means the image
         reaches the client as base64 inside text — unreadable to a model — or
         that the clause stopped running the framework's argument gates.
         """
    test "answers an image entry as image content beside its stamps in JSON" do
      reference = reference!("https://tool.example.test/image")

      assert {:ok, [image, text]} =
               Tool.run(%Wymcp.Context{}, %{"action" => "read", "data" => %{"id" => reference.id}})

      assert %{"type" => "image", "mimeType" => "image/png", "data" => data} = image
      assert Base.decode64!(data) == <<137, 80, 78, 71, 13, 10, 26, 10>>
      assert %{"type" => "text", "text" => json} = text
      assert %{"format" => "image/png", "reference" => _id} = decoded = JSON.decode!(json)
      refute Map.has_key?(decoded, "image")
    end

    test "passes a text answer through as one JSON text block" do
      reference = reference!("https://tool.example.test/page")

      assert {:ok, [%{"type" => "text", "text" => json}]} =
               Tool.run(%Wymcp.Context{}, %{"action" => "read", "data" => %{"id" => reference.id}})

      assert %{"text" => "# Page\nsecond line\n"} = JSON.decode!(json)
    end

    test "keeps the framework's gates, and leaves every other action to it" do
      assert {:error, _missing_id, :dispatch} =
               Tool.run(%Wymcp.Context{}, %{"action" => "read", "data" => %{}})

      reference = reference!("https://tool.example.test/page")

      assert {:ok, [%{"type" => "text", "text" => json}]} =
               Tool.run(%Wymcp.Context{}, %{"action" => "get", "data" => %{"id" => reference.id}})

      assert %{"reference" => %{"id" => _id}} = JSON.decode!(json)
    end
  end

  describe "refresh" do
    test "runs the recipe now and answers the outcome" do
      reference = reference!("https://tool.example.test/page")

      assert {:ok, %{outcome: "fetched", format: "text/plain"}, %{}} =
               Actions.run(:refresh, %{"id" => reference.id})
    end
  end

  describe "watch and unwatch" do
    test "starts a watch and refreshes once, and unwatch stops it" do
      reference = reference!("https://tool.example.test/page")

      assert {:ok, %{watch: watch, refresh: refresh}, %{}} =
               Actions.run(:watch, %{
                 "id" => reference.id,
                 "cadence_minutes" => 15,
                 "lifetime_hours" => "2"
               })

      assert %{name: name, watch: %{reference: _id}, cron_expression: "*/15 * * * *"} = watch
      assert %{outcome: "fetched"} = refresh

      assert {:ok, %{removed: ^name}, %{}} = Actions.run(:unwatch, %{"id" => reference.id})
      assert Schedules.list() == []
    end

    test "reports a failed first refresh beside the watch it still starts" do
      reference = reference!("https://legacy.example.test/page")

      assert {:ok, %{watch: %{name: _name}, refresh: %{error: error}}, %{}} =
               Actions.run(:watch, %{
                 "id" => reference.id,
                 "cadence_minutes" => 5,
                 "lifetime_hours" => 1
               })

      assert error =~ "predates the cache contract"
      assert [%{watch: _watch}] = Schedules.list()
    end

    test "refuses a cadence or lifetime outside the watch's bounds, and a missing one" do
      reference = reference!("https://tool.example.test/page")
      base = %{"id" => reference.id, "cadence_minutes" => 15, "lifetime_hours" => 1}

      for {change, words} <- [
            {%{"cadence_minutes" => 10}, "5, 15, 30 or 60"},
            {%{"lifetime_hours" => 13}, "1 to 12"},
            {%{"lifetime_hours" => "soon"}, "Invalid lifetime_hours"}
          ] do
        assert {:error, {reason, ctx}} = Actions.run(:watch, Map.merge(base, change))
        assert Tool.handle_error({reason, ctx}) =~ words
      end

      assert Schedules.list() == []
    end

    test "unwatch refuses a reference that has no watch" do
      reference = reference!("https://tool.example.test/page")

      assert {:error, {reason, ctx}} = Actions.run(:unwatch, %{"id" => reference.id})
      assert Tool.handle_error({reason, ctx}) =~ "has no watch"
    end
  end

  defp reference!(uri) do
    {:ok, reference} = References.create_reference(%{title: "A page", uri: uri})
    reference
  end

  defp script! do
    segment = "ToolCache#{System.unique_integer([:positive])}"
    on_exit(fn -> Compiler.purge(Module.concat(["Script", segment])) end)

    code = ~S"""
    defmodule Script.SEGMENT do
      use YmerNode.Script

      @impl true
      def description, do: "answers tool.example.test pages"

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
        do: %{hosts: ["tool.example.test"], url_action: :fetch, secrets: [], cache: :file}

      @impl true
      def run(:fetch, %{"url" => url} = args, _context), do: answer(URI.parse(url).path, args)

      defp answer("/page", args), do: write(args, "# Page\nsecond line\n", "text/plain")
      defp answer("/image", args), do: write(args, <<137, 80, 78, 71, 13, 10, 26, 10>>, "image/png")

      defp write(%{"cache_path" => path}, bytes, format) do
        File.write!(path, bytes)
        {:ok, %{"format" => format}}
      end
    end
    """

    assert {:ok, script} = Scripts.create(String.replace(code, "SEGMENT", segment))
    script
  end

  defp legacy_script! do
    segment = "ToolLegacy#{System.unique_integer([:positive])}"
    on_exit(fn -> Compiler.purge(Module.concat(["Script", segment])) end)

    code = ~S"""
    defmodule Script.SEGMENT do
      use YmerNode.Script

      @impl true
      def description, do: "answers legacy.example.test the way it always has"

      @impl true
      def actions do
        %{
          fetch: %{
            description: "one page, summarised",
            properties: %{"url" => %{"type" => "string"}},
            required: ["url"],
            write: false
          }
        }
      end

      @impl true
      def declarations, do: %{hosts: ["legacy.example.test"], url_action: :fetch, secrets: []}

      @impl true
      def run(:fetch, _args, _context), do: {:ok, %{"summary" => "the old shape"}}
    end
    """

    assert {:ok, script} = Scripts.create(String.replace(code, "SEGMENT", segment))
    script
  end
end
