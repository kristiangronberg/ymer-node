defmodule YmerNode.Scripts.LibrariesTest do
  use ExUnit.Case, async: true

  alias YmerNode.Scripts.Libraries

  doctest YmerNode.Scripts.Libraries

  defp library(version), do: %{kind: :library, version: version, loaded?: true, error: nil}

  describe "check_held/3" do
    test "holds a script whose every library is loaded at a version in range" do
      held = %{"crosskey" => library("1.2.0"), "jira" => library("0.3.1")}
      declared = %{"crosskey" => "~> 1.0", "jira" => ">= 0.0.0"}

      assert :ok = Libraries.check_held("sync", declared, held)
      assert :ok = Libraries.check_held("sync", %{}, %{})
    end

    test "refuses a library the node does not hold, naming the requirement and the fix" do
      assert {:error, {:library_missing, detail}} =
               Libraries.check_held("sync", %{"crosskey" => "~> 1.0"}, %{})

      assert detail ==
               "sync declares the library crosskey (~> 1.0), which this node does not hold " <>
                 "— create or import crosskey, then store sync again — with `create` if it " <>
                 "is new, or `update` if it is stored, which accepts the same code; a stored " <>
                 "one is otherwise checked again only when the node restarts"
    end

    test "refuses a name that is a script, not a library" do
      held = %{"crosskey" => %{library("1.0.0") | kind: :script}}

      assert {:error, {:library_missing, detail}} =
               Libraries.check_held("sync", %{"crosskey" => "~> 1.0"}, held)

      assert detail =~ "crosskey here is a script"
    end

    test "names a Broken script row as a script, not as a library to fix" do
      held = %{
        "crosskey" => %{
          library("1.0.0")
          | kind: :script,
            loaded?: false,
            error: {:missing_callbacks, "version/0"}
        }
      }

      assert {:error, {:library_missing, detail}} =
               Libraries.check_held("sync", %{"crosskey" => "~> 1.0"}, held)

      assert detail =~ "crosskey here is a script"
    end

    test "refuses a library held at a version outside the requirement, naming both" do
      held = %{"crosskey" => library("2.0.0")}

      assert {:error, {:library_out_of_range, detail}} =
               Libraries.check_held("sync", %{"crosskey" => "~> 1.0"}, held)

      assert detail =~ "sync declares the library crosskey ~> 1.0"
      assert detail =~ "this node holds crosskey 2.0.0"
      assert detail =~ "then store sync again"
    end

    test "refuses a Broken row, carrying its own failure, as the loader records it" do
      broken = %{library(nil) | kind: nil, loaded?: false, error: {:compile_error, "boom"}}

      assert {:error, {:library_broken, detail}} =
               Libraries.check_held("sync", %{"crosskey" => "~> 1.0"}, %{"crosskey" => broken})

      assert detail =~ "the row crosskey could not compile here (compile_error: boom)"
      assert detail =~ "fix crosskey, then store sync again"
      refute detail =~ "which this node holds"
    end

    test "names the first library by name when several are not held" do
      assert {:error, {:library_missing, detail}} =
               Libraries.check_held("sync", %{"zeta" => "~> 1.0", "alpha" => "~> 1.0"}, %{})

      assert detail =~ "the library alpha"
    end
  end

  describe "dependents/2" do
    test "answers each script declaring the library, with its requirement, by name" do
      rows = [
        {"sync", %{"libraries" => %{"crosskey" => "~> 1.0"}}},
        {"audit", %{"libraries" => %{"crosskey" => ">= 0.0.0", "jira" => "~> 2.0"}}},
        {"hex", %{"hosts" => ["hex.pm"]}},
        {"crosskey", %{}}
      ]

      assert Libraries.dependents("crosskey", rows) == [
               {"audit", ">= 0.0.0"},
               {"sync", "~> 1.0"}
             ]

      assert Libraries.dependents("nobody", rows) == []
    end
  end

  describe "check_removable/2" do
    test "lets a library with no dependents go, and names every dependent otherwise" do
      assert :ok = Libraries.check_removable("crosskey", [])

      assert {:error, {:library_in_use, detail}} =
               Libraries.check_removable("crosskey", [{"audit", ">= 0.0.0"}, {"sync", "~> 1.0"}])

      assert detail ==
               "crosskey is declared by audit (>= 0.0.0), sync (~> 1.0) — update those " <>
                 "scripts to stop declaring it, or remove them, first"
    end
  end

  describe "check_in_range/3" do
    test "lets a version inside every requirement land, and names each it falls outside" do
      dependents = [{"audit", ">= 0.0.0"}, {"sync", "~> 1.0"}]

      assert :ok = Libraries.check_in_range("crosskey", "1.4.0", dependents)

      assert {:error, {:requirement_broken, detail}} =
               Libraries.check_in_range("crosskey", "2.0.0", dependents)

      assert detail ==
               "crosskey 2.0.0 is outside what sync (~> 1.0) require — widen those " <>
                 "requirements first, or keep the version in range"
    end
  end
end
