defmodule YmerNode.Mcp.Tools.Scripts.SchemasTest do
  @moduledoc """
  Pure data, so `async: true`. What is pinned here is the *contract* a client
  reads — the action set, the required lists, and the two notes a worker acts on
  — not the prose around them.
  """
  use ExUnit.Case, async: true

  alias YmerNode.Mcp.Tools.Scripts.Schemas
  alias YmerNode.Scripts.PackageDocs

  test "serves exactly list, describe, guide, info and run" do
    assert Schemas.all() |> Map.keys() |> Enum.sort() == [:describe, :guide, :info, :list, :run]
  end

  test "info takes a promised package's name and nothing else" do
    assert Schemas.all().info.required == ["name"]
    assert Map.keys(Schemas.all().info.properties) == ["name"]
    assert Schemas.all().info.properties["name"]["enum"] == PackageDocs.names()
    assert Schemas.all().info.notes =~ "before the first script"
    assert Schemas.all().info.notes =~ "`guide`"
  end

  test "guide takes nothing and is the call to make before writing a script" do
    assert Schemas.all().guide.required == []
    assert Schemas.all().guide.properties == %{}
    assert Schemas.all().guide.notes =~ "before writing a script"
    assert Schemas.all().guide.notes =~ "`script_author check`"
  end

  test "requires what each action cannot work without" do
    assert Schemas.all().list.required == []
    assert Schemas.all().describe.required == ["script"]
    assert Schemas.all().info.required == ["name"]
    assert Schemas.all().run.required == ["script", "action"]
  end

  test "defaults code off and args empty" do
    assert Schemas.all().describe.defaults == %{"code" => false}
    assert Schemas.all().run.defaults == %{"args" => %{}}
  end

  @tag doc: """
       `run`'s note has to state three things a caller cannot discover by
       trying: that an unaccepted script is refused and how to accept it, that
       the run is killed at a deadline, and that what a killed run already did
       outside this node stands. A failure here means the wire stopped saying
       one of them, and a worker would learn it from a half-finished side
       effect instead.
       """
  test "run's note carries acceptance, the deadline, and the killed-run warning" do
    notes = Schemas.all().run.notes

    assert notes =~ "accepted"
    assert notes =~ "5 minutes"
    assert notes =~ "killed"
    assert notes =~ "OUTSIDE this node may already have landed"
  end

  test "describe's note steers at the write mark rather than describing the field" do
    assert Schemas.all().describe.notes =~ "Read before you write"
    assert Schemas.all().describe.notes =~ "never appear"
  end
end
