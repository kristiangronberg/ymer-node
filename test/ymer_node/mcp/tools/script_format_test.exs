defmodule YmerNode.Mcp.Tools.ScriptFormatTest do
  @moduledoc """
  Pure shaping — no database, no VM state, so `async: true`.

  Every fixture here is written by hand rather than produced by
  `YmerNode.Scripts`: this module's subject is the *translation* to the wire, and
  a fixture that came from the context would move whenever the context did and
  stop telling you which of the two broke.
  """
  use ExUnit.Case, async: true

  alias YmerNode.Mcp.Tools.ScriptFormat

  @entry %{
    name: "hex",
    description: "packages on hex.pm",
    origin: "authored",
    accepted?: true,
    loaded?: true,
    actions: [:fetch, :package],
    error: nil
  }

  @schemas %{
    package: %{
      description: "one package",
      properties: %{"name" => %{"type" => "string"}},
      required: ["name"],
      write: false
    },
    fetch: %{
      description: "a url",
      properties: %{"url" => %{"type" => "string"}},
      required: ["url"],
      write: true,
      timeout: 60_000
    }
  }

  describe "summary/1" do
    test "renames the predicates and stringifies the action names" do
      assert ScriptFormat.summary(@entry) == %{
               name: "hex",
               description: "packages on hex.pm",
               origin: "authored",
               accepted: true,
               loaded: true,
               actions: ["fetch", "package"]
             }
    end

    test "renders a script that will not run, with the reason it will not" do
      failure = {:syntax_error, "script:hex:3: oops"}
      broken = %{@entry | loaded?: false, actions: [], error: failure}

      rendered = ScriptFormat.summary(broken)
      assert rendered.loaded == false
      assert rendered.error == "syntax_error: script:hex:3: oops"
      refute Map.has_key?(rendered, :actions)
    end

    @tag doc: """
         `loaded: false` must survive the compaction that removes nils and empty
         lists. A failure here means a broken script is rendered as though the
         key were simply absent, and a client reading "no loaded key" as "fine"
         would show a script that cannot run as one that can.
         """
    test "keeps a false flag rather than compacting it away" do
      rendered = ScriptFormat.summary(%{@entry | accepted?: false, loaded?: false})

      assert rendered.accepted == false
      assert rendered.loaded == false
    end
  end

  describe "actions/1" do
    test "keys by the action's name as a string and keeps every write mark" do
      rendered = ScriptFormat.actions(@schemas)

      assert Map.keys(rendered) |> Enum.sort() == ["fetch", "package"]
      assert rendered["fetch"].write == true
      assert rendered["fetch"].timeout == 60_000
      assert rendered["package"].write == false
    end

    @tag doc: """
         A `write: false` action must still carry the key. It is the flag a
         worker reads before deciding whether it may act, and a key that vanishes
         when false is one a reader learns to stop checking — the exact failure
         the read-before-write rule exists to prevent.
         """
    test "carries write: false rather than dropping it" do
      assert %{"package" => package} = ScriptFormat.actions(@schemas)
      assert Map.has_key?(package, :write)
      assert package.write == false
      refute Map.has_key?(package, :timeout)
    end
  end

  describe "detail/1" do
    test "adds the row's own facts and formats the timestamp" do
      accepted_at = ~U[2026-09-09 08:30:00Z]

      detail =
        @entry
        |> Map.merge(%{
          contract: 1,
          accepted_at: accepted_at,
          declarations: %{"hosts" => ["hex.pm"], "url_action" => "fetch", "secrets" => []},
          actions: @schemas,
          warnings: [],
          code: nil
        })
        |> ScriptFormat.detail()

      assert detail.name == "hex"
      assert detail.contract == 1
      assert detail.accepted_at == "2026-09-09T08:30:00Z"
      assert detail.declarations["hosts"] == ["hex.pm"]
      assert %{"fetch" => %{write: true}} = detail.actions
      refute Map.has_key?(detail, :code)
      refute Map.has_key?(detail, :warnings)
    end

    test "carries the code when it was asked for" do
      detail =
        @entry
        |> Map.merge(%{
          contract: 1,
          accepted_at: nil,
          declarations: %{},
          actions: @schemas,
          warnings: ["script:hex:9:3: unused variable"],
          code: "defmodule Script.Hex do\nend\n"
        })
        |> ScriptFormat.detail()

      assert detail.code == "defmodule Script.Hex do\nend\n"
      assert detail.warnings == ["script:hex:9:3: unused variable"]
    end
  end

  describe "checked/1" do
    test "answers a candidate's shape with no origin and no acceptance" do
      checked =
        ScriptFormat.checked(%{
          name: "hex",
          description: "packages on hex.pm",
          contract: 1,
          declarations: %{hosts: [], url_action: nil, secrets: []},
          actions: @schemas,
          warnings: [],
          existing: true
        })

      assert checked.name == "hex"
      assert checked.contract == 1
      assert %{"package" => %{write: false}} = checked.actions
      assert checked.existing == true
      refute Map.has_key?(checked, :accepted)
      refute Map.has_key?(checked, :origin)
    end

    @tag doc: """
         `existing` survives the compaction that drops every other empty value.
         It is the whole round trip this call saves — false means `create` will
         be taken, true means it will be refused — and a caller that stopped
         seeing the key on the common answer would stop reading it on the other
         one too.
         """
    test "keeps the existing flag when it is false" do
      checked =
        ScriptFormat.checked(%{
          name: "hex",
          description: "packages on hex.pm",
          contract: 1,
          declarations: %{hosts: [], url_action: nil, secrets: []},
          actions: @schemas,
          warnings: [],
          existing: false
        })

      assert checked.existing == false
    end
  end
end
