defmodule YmerNode.References.SeamTest do
  @moduledoc """
  Counts the queries one references operation makes against the `scripts` table.

  This module exists because the rule it guards is invisible everywhere else. A
  second read of `YmerNode.References.Sources.declarations/0` inside one call
  changes no answer and breaks no other test: it costs a query, and — if the two
  reads straddled an `accept` — could let one response classify two references
  by two different sets of declarations. Nothing but counting catches that.

  The counter is `Ecto.Repo`'s own telemetry event, whose measurement carries
  the source table. `metadata.source` is the string Ecto puts there for the
  table a query reads, so `"scripts"` is exactly the seam and nothing else —
  an earlier attempt matched the query TEXT for "script" and was fooled by the
  word `description` in the reference columns, which is why the assertion reads
  a structured field rather than SQL.

  Not async: it attaches a telemetry handler under a fixed name and writes rows.
  """
  use YmerNode.DataCase

  alias YmerNode.Mcp.Tools.References.Actions
  alias YmerNode.Mcp.Tools.References.Errors
  alias YmerNode.References
  alias YmerNode.References.Sources
  alias YmerNode.Scripts.Script

  setup do
    parent = self()
    handler = "seam-counter-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:ymer_node, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        send(parent, {:query, metadata.source})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  describe "one read of the seam per operation" do
    @tag doc: """
         The regression gate for the whole seam. `find` with a source filter is
         the worst case: the filter classifies, the renderer renders, the
         validator checks the token against the vocabulary and the error path
         may list it — four places that each once read the seam for themselves.
         A failure with a count ABOVE one means a layer went back to the
         database; the fix is to thread the declarations the action already has,
         never to relax this number.
         """
    test "a source-filtered find reads the scripts table exactly once" do
      seed_reference!("https://tracker.example.fi/browse/ABC-1")

      insert_script!("tracker", %{
        "hosts" => ["tracker.example.fi"],
        "url_action" => "issue",
        "secrets" => []
      })

      flush()

      assert {:ok, %{count: 1, results: [hit]}, %{}} =
               Actions.run(:find, %{"source" => "tracker"})

      assert hit.source == "tracker"
      assert scripts_queries() == 1
    end

    test "an unfiltered find reads it exactly once too" do
      seed_reference!("https://elixir-lang.org/docs")
      flush()

      assert {:ok, _answer, %{}} = Actions.run(:find, %{"query" => "docs"})
      assert scripts_queries() == 1
    end

    test "list reads it exactly once" do
      seed_reference!("https://elixir-lang.org/docs")
      flush()

      assert {:ok, %{count: 1}, %{}} = Actions.run(:list, %{})
      assert scripts_queries() == 1
    end

    @tag doc: """
         Both halves of add: a landed insert classifies its row against one
         read, and a refused insert classifies nothing and reads nothing. The
         read sits on the two rendering branches of `add/1`, after the
         changeset has been judged; the zero is what measures that placement.
         """
    test "add reads it once when it lands and not at all when it is refused" do
      flush()

      assert {:ok, _answer, %{id: _id}} =
               Actions.run(:add, %{
                 "title" => "A reference",
                 "uri" => "https://elixir-lang.org/docs"
               })

      assert scripts_queries() == 1

      assert {:error, _refusal} = Actions.run(:add, %{"title" => "", "uri" => 42})
      assert scripts_queries() == 0
    end

    test "get reads it exactly once" do
      reference = seed_reference!("https://elixir-lang.org/docs")
      flush()

      assert {:ok, _answer, %{}} = Actions.run(:get, %{"id" => reference.id})
      assert scripts_queries() == 1
    end

    @tag doc: """
         The one path with no declarations to hand: `handle_error/1` called with
         a bare reason, which no action produces but the tool's own callback
         still accepts. It reads the seam for itself so the message names every
         accepted script rather than only the built-ins — one read, and the
         reason this case lives here rather than in the async errors test, which
         has no database.
         """
    test "an invalid-source message with no declarations in hand reads the seam once" do
      insert_script!("tracker", %{
        "hosts" => ["tracker.example.fi"],
        "url_action" => "issue",
        "secrets" => []
      })

      flush()

      message = Errors.format(:invalid_source)

      assert message =~ "tracker"
      assert scripts_queries() == 1
    end

    @tag doc: """
         The paired positive control. Every count above is a "no more than one",
         and a counter that silently stopped counting would satisfy all of them
         at zero. This one proves the same matcher can see a read at all: two
         deliberate reads register as two.
         """
    test "the counter is not blind — two deliberate reads count as two" do
      flush()

      Sources.declarations()
      Sources.declarations()

      assert scripts_queries() == 2
    end
  end

  defp scripts_queries do
    receive do
      {:query, "scripts"} -> 1 + scripts_queries()
      {:query, _other} -> scripts_queries()
    after
      0 -> 0
    end
  end

  defp flush do
    receive do
      {:query, _source} -> flush()
    after
      0 -> :ok
    end
  end

  defp seed_reference!(uri) do
    {:ok, reference} =
      References.create_reference(%{title: "A reference", uri: uri, tags: ["seed"]})

    reference
  end

  defp insert_script!(name, declarations) do
    code = "defmodule Script.#{Macro.camelize(name)} do\nend\n"
    hash = Script.hash(code)

    %Script{}
    |> Script.changeset(%{
      name: name,
      code: code,
      code_hash: hash,
      accepted_hash: hash,
      accepted_at: DateTime.utc_now() |> DateTime.truncate(:second),
      origin: "authored",
      contract: 1,
      description: name,
      declarations: declarations
    })
    |> Repo.insert!()
  end
end
