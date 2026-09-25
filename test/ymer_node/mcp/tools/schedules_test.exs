defmodule YmerNode.Mcp.Tools.SchedulesTest do
  @moduledoc """
  Pins the tool's wiring: that the framework accepts its action schemas, and
  that the surface a client meets is the one this repo means to serve. The
  validation call matters for the reason `YmerNode.Mcp.Tools.ScriptsTest` gives:
  nothing else in `mix test` makes it, and a malformed schema would fail the
  whole `/mcp` endpoint.
  """
  use ExUnit.Case, async: true

  alias Wymcp.Tool.Actions
  alias Wymcp.Tool.Schema
  alias YmerNode.Mcp.Tools.Schedules

  describe "tool wiring" do
    test "passes framework validation and exposes the expected surface" do
      assert :ok = Actions.validate!(Schedules)

      assert %{"properties" => %{"action" => %{"enum" => [_ | _]}}} = Schema.build(Schedules)

      assert Schedules.name() == "schedules"
      assert Schedules.title() == "Schedules"
    end

    test "is annotated destructive and open-world" do
      assert Schedules.annotations() == %{"destructiveHint" => true, "openWorldHint" => true}
    end

    @tag doc: """
         The only text this node can put in front of the person setting the
         tool's permission. A failure means the line asking for approval was
         lost, and a client may let a session set scripts running unattended
         without anyone deciding it should.
         """
    test "the description asks the person setting its permission to set it to ask" do
      assert Schedules.description() =~ "Needs approval"
      assert Schedules.description() =~ "set it to ask"
    end
  end

  describe "handle_error/1" do
    test "renders both the bare reason and the reason-with-context shapes" do
      assert Schedules.handle_error({:not_found, "no schedule named x"}) =~ "no schedule named x"

      assert Schedules.handle_error(
               {{:not_found, "no schedule named x"}, %{action_verb: "remove"}}
             ) =~
               "no schedule named x"
    end

    test "renders a changeset's errors as text, not as the struct" do
      changeset =
        %YmerNode.Schedules.Schedule{}
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.add_error(:args, "is invalid")

      message = Schedules.handle_error(changeset)

      assert message =~ "The schedule could not be stored"
      assert message =~ "is invalid"
      refute message =~ "Ecto.Changeset"
    end
  end
end
