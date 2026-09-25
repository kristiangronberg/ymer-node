defmodule YmerNode.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(children(), strategy: :one_for_one, name: YmerNode.Supervisor)
  end

  # Order is load-bearing. The node database's repo comes up before the
  # migrator that migrates it; the scripts loader comes up after that migrator,
  # because it reads rows the migrator has to have built, and before the
  # listener, because a `scripts run` must never reach a VM that has not
  # compiled what it is about to run. The notebook's repo comes up before the
  # probe that queries it and before the lock that guards its files; and the
  # HTTP listener is last so the node never accepts a call it cannot yet serve —
  # which includes a references call, whose registry the migrator has to have
  # built.
  #
  # The process registry and the task supervisor belong to the runner — one
  # records which scripts have a run in flight, the other owns the run
  # processes — and the task supervisor is also what the compiler bounds every
  # compile with. Both come up before the migrator, because the migration that
  # plants the example script compiles it, and a compile with no supervisor to
  # run under would end that boot in a `:noproc` exit.
  #
  # The throttles' process registry and supervisor come up beside them, before
  # the loader: a throttle is started by the first request that names it, and
  # only a run of a loaded script makes a request.
  #
  # The schedules' process registry comes up beside them, before the loader,
  # because the loader reads it: a refusal to replace a script while a firing's
  # run of it is in flight names the schedule, and the refusal that holds is
  # taken inside the loader's own message.
  #
  # The scheduler comes up after the loader and after the notebook's own
  # children, just ahead of the listener, with its firing supervisor ahead of
  # it. A firing runs a script the loader has to have compiled, and that script
  # may read or write the notebook: a firing is a call the node makes of
  # itself, and like the listener's calls it must never reach a notebook that
  # is not up. Neither is part of a script's run, so neither joins
  # `run_tree/0`: a run a firing starts is a run like any other, under the
  # runner's task supervisor.
  #
  # Public, and `@doc false`, ONLY so a test can read the list back — it is the
  # one way to gate a rule about a list. Two tests do: `YmerNode.ApplicationTest`
  # gates the order above, and `YmerNode.ScriptHarnessTest` pins
  # `YmerNode.Script.Harness.run_tree/0` as a transcription of the children a
  # script's run needs — the task supervisor and the throttles' process registry
  # and supervisor. A new child a script's run needs goes into `run_tree/0` too:
  # that test catches an edit to those children, never an addition beside them.
  @doc false
  def children do
    [
      YmerNode.Repo,
      {Registry, keys: :duplicate, name: YmerNode.Scripts.Runs},
      {Task.Supervisor, name: YmerNode.Scripts.TaskSupervisor},
      {Registry, keys: :unique, name: YmerNode.Scripts.Throttles},
      {DynamicSupervisor, name: YmerNode.Scripts.ThrottleSupervisor, strategy: :one_for_one},
      {Registry, keys: :unique, name: YmerNode.Schedules.InFlight},
      migrator(),
      YmerNode.Scripts.Loader,
      YmerNode.Notebook.Repo,
      YmerNode.Notebook.VecLoadCheck,
      YmerNode.Notebook.Backup.Lock,
      {Task.Supervisor, name: YmerNode.Schedules.FiringSupervisor},
      YmerNode.Schedules.Scheduler,
      mcp_endpoint()
    ]
  end

  # Migrations run at every boot, in every environment, and nothing turns them
  # off: the `:skip` key is deliberately absent, so no variable can leave a node
  # serving a registry its code does not match. The child migrates synchronously
  # inside its own `init/1` and then returns `:ignore` — it holds the rest of the
  # tree until the node database is current and leaves no process behind, which
  # is why it sits here as a step rather than as a supervised service.
  defp migrator do
    {Ecto.Migrator, repos: [YmerNode.Repo]}
  end

  # The bind address is not a preference — it is half the compensating control for
  # an unauthenticated /mcp, and which half depends on where the node runs.
  # `YmerNode.Mcp` owns that decision; this function only asks it.
  defp mcp_endpoint do
    {Bandit, plug: YmerNode.Mcp.Endpoint, ip: YmerNode.Mcp.ip(), port: YmerNode.Mcp.port()}
  end
end
