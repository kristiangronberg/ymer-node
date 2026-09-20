defmodule YmerNode.Mcp.Tools.ScriptAuthor.SchemasTest do
  @moduledoc """
  Pure data, so `async: true`. What is pinned is the contract a client reads —
  the action set, the required lists, the pointer at the guide an author reads
  before writing, and the acceptance paragraph.
  """
  use ExUnit.Case, async: true

  alias YmerNode.Mcp.Tools.ScriptAuthor.Schemas

  test "serves exactly check, create, update, accept and remove" do
    assert Schemas.all() |> Map.keys() |> Enum.sort() ==
             [:accept, :check, :create, :remove, :update]
  end

  test "requires what each action cannot work without" do
    assert Schemas.all().check.required == ["code"]
    assert Schemas.all().create.required == ["code"]
    assert Schemas.all().update.required == ["script", "code"]
    assert Schemas.all().accept.required == ["script"]
    assert Schemas.all().remove.required == ["script"]
  end

  @tag doc: """
       `create` takes no `script` argument, and that is the contract rather than
       an omission: the name is derived from the module. A failure here means
       someone added one, and two sources of truth for a script's name is
       exactly what D1 settled against.
       """
  test "create takes code alone — the name is derived, never given" do
    assert Map.keys(Schemas.all().create.properties) == ["code"]
  end

  @tag doc: """
       The contract itself is not in these notes and must not come back: it is
       `scripts guide`'s, rendered from `YmerNode.Script`'s own docs, and a copy
       here would be a second text to keep in step. A failure on the negative
       half means the contract paragraph was pasted back; on the positive half,
       that an author is no longer told where to read it.
       """
  test "check and create both point at the guide rather than restating the contract" do
    for action <- [:check, :create] do
      notes = Schemas.all()[action].notes

      assert notes =~ "`scripts guide`"
      refute notes =~ "use YmerNode.Script"
    end
  end

  @tag doc: """
       The round trip `check` exists to save. An LLM caller reads the notes and
       nothing else, so a field it is never told about is a field it never
       reads: without this sentence `existing` ships and no client asks for it,
       and the collision goes on surfacing as a refused `create`.
       """
  test "check says what the existing flag means" do
    notes = Schemas.all().check.notes

    assert notes =~ "existing"
    assert notes =~ "`update` is the call to make"
  end

  test "every acceptance door states what acceptance refuses" do
    for action <- [:create, :update, :accept] do
      assert Schemas.all()[action].notes =~ "Acceptance refuses five things"
    end
  end

  @tag doc: """
       `update` has to say three things that cost data if unsaid: it replaces
       whole rather than patching, there is no history, and the name may not
       change. A failure means an author can lose a script to a call it thought
       was a patch.
       """
  test "update warns that it replaces, keeps no history, and cannot rename" do
    notes = Schemas.all().update.notes

    assert notes =~ "Whole replacement"
    assert notes =~ "no version history"
    assert notes =~ "SAME name"
    assert notes =~ "in flight"
  end

  test "remove says the code is not kept and that references fall back" do
    assert Schemas.all().remove.notes =~ "not kept anywhere"
    assert Schemas.all().remove.notes =~ "falls back"
  end
end
