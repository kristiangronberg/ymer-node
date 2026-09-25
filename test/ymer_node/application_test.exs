defmodule YmerNode.ApplicationTest do
  @moduledoc """
  Reads the child list back rather than the running tree: `Supervisor.which_children/1`
  says nothing this suite may rely on about order, and two of the children
  (`Ecto.Migrator`, `YmerNode.Notebook.VecLoadCheck`) return `:ignore` and leave
  no process to find. The list is a pure read, so `async: true`.
  """
  use ExUnit.Case, async: true

  defp names, do: Enum.map(YmerNode.Application.children(), &child_name/1)

  defp child_name({Ecto.Migrator, _options}), do: :migrator
  defp child_name({Bandit, _options}), do: :listener
  defp child_name({Registry, options}), do: Keyword.fetch!(options, :name)
  defp child_name({Task.Supervisor, options}), do: Keyword.fetch!(options, :name)
  defp child_name({DynamicSupervisor, options}), do: Keyword.fetch!(options, :name)
  defp child_name(module) when is_atom(module), do: module

  defp position(name), do: Enum.find_index(names(), &(&1 == name))

  describe "the supervision tree" do
    @tag doc: """
         Pins the boot order the scripts capability rests on. The loader
         compiles every accepted row out of the node database, so it has to
         start after the migrator that creates that table and before the
         listener that can be asked to run one. A failure means either a boot
         that reads a table nothing has created, or a `scripts run` reaching a
         VM with nothing compiled — and the second answers "not accepted" for a
         script that is. The rule itself is stated at `children/0`.
         """
    test "the scripts loader sits after the migrator and before the listener" do
      assert position(:migrator) < position(YmerNode.Scripts.Loader)
      assert position(YmerNode.Scripts.Loader) < position(:listener)
    end

    test "the runner's process registry and task supervisor are in the tree" do
      assert YmerNode.Scripts.Runs in names()
      assert YmerNode.Scripts.TaskSupervisor in names()
    end

    @tag doc: """
         A throttle is started by the first request naming it, under this
         supervisor and found through this process registry, and a request is
         made only by a run of a loaded script. A failure means a run could
         reach a throttle before either exists, and die with a `:noproc` exit
         that names neither.
         """
    test "the throttles' process registry and supervisor sit before the loader" do
      assert position(YmerNode.Scripts.Throttles) < position(YmerNode.Scripts.Loader)
      assert position(YmerNode.Scripts.ThrottleSupervisor) < position(YmerNode.Scripts.Loader)
    end

    @tag doc: """
         The migration that plants the example script compiles it, and the
         compiler runs every compile under the task supervisor, so the
         supervisor has to exist before the migrator runs. A failure means a
         fresh node database's first boot dies inside that migration with a
         `:noproc` exit — which nothing else in the suite reaches, because the
         test configuration turns the planting off.
         """
    test "the task supervisor sits before the migrator that plants the example script" do
      assert position(YmerNode.Scripts.TaskSupervisor) < position(:migrator)
    end

    @tag doc: """
         The loader reads the schedules' process registry inside the message
         that purges a script, to name the schedule whose firing holds a run.
         A failure means that read could meet no process registry at all, and
         a write refused for a run in flight would crash the loader instead.
         """
    test "the schedules' process registry sits before the loader" do
      assert position(YmerNode.Schedules.InFlight) < position(YmerNode.Scripts.Loader)
    end

    @tag doc: """
         A firing runs a script the loader has to have compiled, that script
         may use the notebook, and the firing runs in a task under the firing
         supervisor. A failure means the scheduler could start a firing before
         one of them exists: a run answered "not loaded" for a script that is,
         a notebook call meeting no repo, or a firing dying with a `:noproc`
         exit.
         """
    test "the scheduler sits after the loader, the notebook and its firing supervisor" do
      assert position(YmerNode.Scripts.Loader) < position(YmerNode.Schedules.Scheduler)
      assert position(YmerNode.Notebook.Repo) < position(YmerNode.Schedules.Scheduler)
      assert position(YmerNode.Notebook.Backup.Lock) < position(YmerNode.Schedules.Scheduler)

      assert position(YmerNode.Schedules.FiringSupervisor) <
               position(YmerNode.Schedules.Scheduler)

      assert position(YmerNode.Schedules.Scheduler) < position(:listener)
    end

    @tag doc: """
         The control for the order cases above: every position they compare has
         to resolve, or a renamed child would make `nil < nil` and the cases
         would pass while guarding nothing.
         """
    test "every child the order cases name is actually in the list" do
      for name <- [
            :migrator,
            :listener,
            YmerNode.Scripts.Loader,
            YmerNode.Notebook.Repo,
            YmerNode.Notebook.Backup.Lock,
            YmerNode.Schedules.FiringSupervisor,
            YmerNode.Schedules.Scheduler,
            YmerNode.Scripts.TaskSupervisor,
            YmerNode.Scripts.Throttles,
            YmerNode.Schedules.InFlight,
            YmerNode.Scripts.ThrottleSupervisor
          ] do
        assert is_integer(position(name)), "#{inspect(name)} is not in children/0"
      end
    end
  end
end
