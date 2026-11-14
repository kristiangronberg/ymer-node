defmodule YmerNode.Repo.Migrations.AddKindAndVersionToScriptsTest do
  use ExUnit.Case, async: true

  @tag doc: """
       The migrations that plant the example scripts write through the current
       schema, so the two columns must exist before the first of them runs. A
       failure means this migration's version was moved after one of them, and
       a fresh node database fails at its first boot.
       """
  test "sorts ahead of every migration that plants an example script" do
    names =
      "priv/repo/migrations/*.exs"
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.map(&Path.basename/1)

    columns =
      Enum.find_index(names, &String.ends_with?(&1, "_add_kind_and_version_to_scripts.exs"))

    plants = for {name, index} <- Enum.with_index(names), name =~ "_plant_", do: index

    assert is_integer(columns)
    assert [_ | _] = plants
    assert Enum.all?(plants, &(&1 > columns))
  end
end
