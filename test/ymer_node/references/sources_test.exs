defmodule YmerNode.References.SourcesTest do
  @moduledoc """
  Every `classify/2` case passes its declarations explicitly rather than reading
  the seam, which is why the bulk of this module needs no database.

  `declarations/0` is the exception and the reason the module is **not** async:
  it is a query now, and its cases write script rows. They live here rather than
  beside the scripts context because what they pin is this module's contract —
  which rows contribute a declaration, and what shape one takes.
  """
  use YmerNode.DataCase

  alias YmerNode.References.Sources
  alias YmerNode.Scripts.Script

  doctest YmerNode.References.Sources

  @tracker %{name: "tracker", hosts: ["tracker.example.fi"], action: "issue"}
  @wiki %{name: "wiki", hosts: ["wiki.example.fi", "docs.example.fi"], action: "page"}
  @declarations [@wiki, @tracker]

  defp classify(uri, declarations \\ @declarations), do: Sources.classify(uri, declarations)

  describe "classify/2 — declared sources" do
    test "a claimed host resolves to the script's name and a scripts-run recipe" do
      assert %{source: "tracker", recipe: recipe} =
               classify("https://tracker.example.fi/browse/ABC-1")

      assert recipe == %{
               tool: "scripts",
               action: "run",
               params: %{
                 "script" => "tracker",
                 "action" => "issue",
                 "args" => %{"url" => "https://tracker.example.fi/browse/ABC-1"}
               }
             }
    end

    test "one script may claim several hosts" do
      assert %{source: "wiki"} = classify("https://wiki.example.fi/display/X")
      assert %{source: "wiki"} = classify("https://docs.example.fi/display/X")
    end

    @tag doc: """
         A port is no part of a claim — `URI.parse/1` yields the host alone — so
         an install reaching a system on a non-default port still gets its
         recipe. A failure means the claim started comparing authorities rather
         than hosts, and every ported uri silently degraded to `web`.
         """
    test "a port on the uri does not defeat the claim" do
      assert %{source: "tracker"} = classify("https://tracker.example.fi:8443/browse/ABC-1")
    end

    @tag doc: """
         DNS is case-insensitive, so a uri pasted with a capitalised host must
         classify the same as a lowercase one. A failure means a user's
         copy-paste decides whether their reference carries a recipe.
         """
    test "hosts are compared downcased, on both sides" do
      assert %{source: "tracker"} = classify("https://TRACKER.Example.FI/browse/ABC-1")

      shouty = %{name: "shouty", hosts: ["SHOUTY.EXAMPLE.FI"], action: "get"}
      assert %{source: "shouty"} = classify("https://shouty.example.fi/x", [shouty])
    end

    @tag doc: """
         Determinism when two accepted scripts claim one host: the first by
         script name wins, whatever order the rows arrive in. Refusing the
         collision is acceptance's job upstream; this module's job is never to
         answer differently on two identical calls. A failure means the answer
         depends on row order, and a reference's recipe changes for no reason
         the user can see.
         """
    test "two scripts claiming one host resolve to the first by script name" do
      alpha = %{name: "alpha", hosts: ["shared.example.fi"], action: "fetch"}
      omega = %{name: "omega", hosts: ["shared.example.fi"], action: "fetch"}

      for order <- [[alpha, omega], [omega, alpha]] do
        assert %{source: "alpha"} = classify("https://shared.example.fi/x", order)
      end
    end

    test "a uri is trimmed before it is classified, and travels whole into the recipe" do
      assert %{source: "tracker", recipe: %{params: %{"args" => %{"url" => url}}}} =
               classify("  https://tracker.example.fi/browse/ABC-1  ")

      assert url == "https://tracker.example.fi/browse/ABC-1"
    end
  end

  describe "classify/2 — built-in sources" do
    test "http(s) on an unclaimed host is web, with no recipe" do
      assert %{source: "web", recipe: nil} = classify("https://elixir-lang.org/docs")
      assert %{source: "web", recipe: nil} = classify("http://example.com")
    end

    @tag doc: """
         A host-less http uri ("https:notes") parses with host nil. Without the
         non-empty-host guard a declaration carrying a blank host would match it
         and attach a recipe that resolves to nothing. A failure means such a uri
         can be claimed by a script that never named it.
         """
    test "a host-less http uri is web, never a declared source" do
      blank = %{name: "blank", hosts: [""], action: "get"}

      assert %{source: "web", recipe: nil} = classify("https:notes", [blank])
      assert %{source: "web", recipe: nil} = classify("http:/path", [blank])
    end

    test "the file scheme and path-like uris are file" do
      assert %{source: "file", recipe: nil} = classify("file:///Users/k/notes.md")
      assert %{source: "file", recipe: nil} = classify("/Users/k/notes.md")
      assert %{source: "file", recipe: nil} = classify("docs/glossary.md")
    end

    test "non-http schemes are other — app deep links are first-class references" do
      assert %{source: "other", recipe: nil} =
               classify("x-devonthink-item://1B0C482D-6725-4E5F-9E36-2C89E1F6A7B0")

      assert %{source: "other", recipe: nil} = classify("mailto:someone@example.fi")
    end

    @tag doc: """
         A Windows drive letter parses as a scheme, so `c:/notes.md` is `other`
         rather than `file`. Recorded as the accepted answer, not a bug: a
         reference with no recipe is still a first-class reference, and guessing
         a drive path apart from a scheme would misclassify real app links.
         """
    test "a Windows drive path parses as a scheme and lands in other" do
      assert %{source: "other", recipe: nil} = classify("c:/Users/k/notes.md")
    end

    test "with no declarations at all, every uri lands on a built-in" do
      assert %{source: "web"} = classify("https://tracker.example.fi/browse/ABC-1", [])
      assert %{source: "file"} = classify("/Users/k/notes.md", [])
      assert %{source: "other"} = classify("mailto:someone@example.fi", [])
    end
  end

  describe "declarations/0 and vocabulary/0" do
    test "an empty registry declares nothing, so the vocabulary is the built-ins" do
      assert Sources.declarations() == []
      assert Sources.vocabulary() == ["file", "other", "web"]
    end

    @tag doc: """
         The vocabulary is computed from the seam rather than stored, because
         the tool's invalid-source message lists it to the caller. A failure
         means the message froze to the built-ins and stopped naming accepted
         scripts, leaving a caller no way to discover them.
         """
    test "an accepted script's declaration joins the seam and the vocabulary" do
      insert_script!("tracker", %{
        "hosts" => ["tracker.example.fi"],
        "url_action" => "issue",
        "secrets" => []
      })

      assert [%{name: "tracker", hosts: ["tracker.example.fi"], action: "issue"}] =
               Sources.declarations()

      assert Sources.vocabulary() == ["file", "other", "tracker", "web"]
    end

    @tag doc: """
         Three ways a row contributes nothing, and each is a real state rather
         than a defensive branch: an UNACCEPTED row is code nobody approved, so
         classifying by it would let unapproved code decide what a reference
         resolves to; a row with no url_action or no hosts would mint a source
         token whose fetch recipe went nowhere. A failure on the first leg is a
         security regression, not a tidiness one.
         """
    test "an unaccepted row, a row with no url_action and a row with no hosts declare nothing" do
      claim = %{"hosts" => ["a.example.fi"], "url_action" => "issue", "secrets" => []}

      insert_script!("unaccepted", claim, accepted: false)
      insert_script!("no_action", %{claim | "url_action" => nil})
      insert_script!("no_hosts", %{claim | "hosts" => []})

      assert Sources.declarations() == []
    end

    test "answers in name order, so two calls agree" do
      claim = fn host -> %{"hosts" => [host], "url_action" => "issue", "secrets" => []} end
      insert_script!("zebra", claim.("z.example.fi"))
      insert_script!("aardvark", claim.("a.example.fi"))

      assert ["aardvark", "zebra"] = Enum.map(Sources.declarations(), & &1.name)
    end
  end

  describe "vocabulary/1" do
    test "answers a sorted vocabulary for the declarations it is handed, reading nothing" do
      assert Sources.vocabulary([@tracker, @wiki]) == ["file", "other", "tracker", "web", "wiki"]
      assert Sources.vocabulary([]) == ["file", "other", "web"]
    end
  end

  defp insert_script!(name, declarations, opts \\ []) do
    code = "defmodule Script.#{Macro.camelize(name)} do\nend\n"
    hash = Script.hash(code)

    %Script{}
    |> Script.changeset(%{
      name: name,
      code: code,
      code_hash: hash,
      accepted_hash: if(Keyword.get(opts, :accepted, true), do: hash, else: "stale"),
      accepted_at: DateTime.utc_now() |> DateTime.truncate(:second),
      origin: "authored",
      contract: 1,
      description: name,
      declarations: declarations
    })
    |> Repo.insert!()
  end
end
