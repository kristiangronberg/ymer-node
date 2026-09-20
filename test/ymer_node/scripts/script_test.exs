defmodule YmerNode.Scripts.ScriptTest do
  @moduledoc """
  Exercises the row through `YmerNode.Repo`, so `YmerNode.DataCase` and no async
  flag. `accepted?/1` and `hash/1` are pure and are covered by the doctests the
  `doctest` line below runs.
  """
  use YmerNode.DataCase

  alias YmerNode.Scripts.Script

  doctest Script

  defp attrs(overrides) do
    code = "defmodule Script.Fixture do\nend\n"

    Map.merge(
      %{
        name: "fixture",
        code: code,
        code_hash: Script.hash(code),
        accepted_hash: Script.hash(code),
        accepted_at: DateTime.utc_now() |> DateTime.truncate(:second),
        origin: "authored",
        contract: 1,
        description: "a fixture",
        declarations: %{"hosts" => [], "url_action" => nil, "secrets" => []}
      },
      overrides
    )
  end

  defp insert(overrides \\ %{}) do
    %Script{} |> Script.changeset(attrs(overrides)) |> Repo.insert()
  end

  describe "accepted/1" do
    test "narrows a query to the rows whose accepted hash is their code hash" do
      Repo.insert!(Script.changeset(%Script{}, attrs(%{name: "runnable"})))

      Repo.insert!(
        Script.changeset(%Script{}, attrs(%{name: "stale", accepted_hash: Script.hash("other")}))
      )

      Repo.insert!(Script.changeset(%Script{}, attrs(%{name: "unaccepted", accepted_hash: nil})))

      assert Script.accepted() |> Repo.all() |> Enum.map(& &1.name) == ["runnable"]
    end
  end

  describe "changeset/2" do
    test "accepts a complete row" do
      assert {:ok, script} = insert()
      assert script.name == "fixture"
      assert Script.accepted?(script)
    end

    test "requires everything the node derives before writing" do
      changeset = Script.changeset(%Script{}, %{})

      assert %{
               name: ["can't be blank"],
               code: ["can't be blank"],
               code_hash: ["can't be blank"],
               origin: ["can't be blank"],
               contract: ["can't be blank"],
               description: ["can't be blank"],
               declarations: ["can't be blank"]
             } = errors_on(changeset)
    end

    test "does not require the acceptance pair, so an unaccepted row is writable" do
      assert {:ok, script} = insert(%{accepted_hash: nil, accepted_at: nil})
      refute Script.accepted?(script)
    end

    test "refuses an origin outside the closed vocabulary" do
      refused = Script.changeset(%Script{}, attrs(%{origin: "guessed"}))
      assert %{origin: ["is invalid"]} = errors_on(refused)
      assert "shipped" in Script.origins()

      for origin <- Script.origins() do
        accepted = Script.changeset(%Script{}, attrs(%{origin: origin}))
        refute Map.has_key?(errors_on(accepted), :origin)
      end
    end

    @tag doc: """
         The name is what `Macro.underscore/1` derives from the code's top
         module, so it can only ever be lowercase snake_case; the format check
         is a backstop against a bug in the derivation rather than against a
         caller, and a failure means a name reached the row by some other path.
         The row's name is also the references source token and the module tree
         it owns, so a name shaped like anything else breaks two things at once.
         """
    test "refuses a name that could not have been derived" do
      for bad <- ["Fixture", "with space", "1leading", "trailing-", ""] do
        assert %{name: [_ | _]} = errors_on(Script.changeset(%Script{}, attrs(%{name: bad})))
      end
    end

    test "refuses a second row with the same name" do
      assert {:ok, _} = insert()
      assert {:error, changeset} = insert(%{code: "defmodule Script.Fixture do\n  # two\nend\n"})
      assert %{name: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "declarations round-trip" do
    @tag doc: """
         Pins the shape the references seam reads. `declarations` is stored as
         JSON, so it comes back with STRING keys whatever went in — a failure
         means the column's type or the configured JSON library changed, and
         `YmerNode.References.Sources` would then be pattern-matching atoms
         against strings and classifying every reference as `web`.
         """
    test "comes back with string keys" do
      assert {:ok, script} =
               insert(%{
                 declarations: %{"hosts" => ["hex.pm"], "url_action" => "fetch", "secrets" => []}
               })

      assert %{"hosts" => ["hex.pm"], "url_action" => "fetch", "secrets" => []} =
               Repo.reload!(script).declarations
    end
  end
end
