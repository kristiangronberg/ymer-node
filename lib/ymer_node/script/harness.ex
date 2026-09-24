defmodule YmerNode.Script.Harness do
  @moduledoc """
  What a VM running script code outside the node needs, for a test or a live
  run: the processes a script's run reaches for, and the three configuration
  keys the node's own environments would otherwise set.

  A repository that develops scripts of its own takes `ymer_node` as a
  dependency under `runtime: false` — the node's code compiles there, and none
  of its applications start. A script run inside the node meets a supervision
  tree and a configuration the node's release, `config/dev.exs` or
  `config/test.exs` arranged; the same script compiled in that repository meets
  neither. This module is the supported way to arrange both, and it carries no
  ExUnit, so a live run's own task calls it as readily as a test does.
  `YmerNode.Script.Test` is the ExUnit layer over it.

  ## A live run

  `run_tree/0` is a child list, never a started tree: the caller starts it
  under a supervisor of its own, once for the whole run, and names that
  supervisor. Once per run is what a live run against a real system wants —
  every script declaring one throttle shares its bucket and its breaker across
  every module of the run, so an account that locks after repeated failed
  logins meets the breaker's threshold once, not once per module.

      {:ok, _pid} =
        Supervisor.start_link(YmerNode.Script.Harness.run_tree(),
          strategy: :one_for_one,
          name: MyScripts.RunTree
        )

  The three setters then point the keys a run reads at the real network, the
  real secrets file and a real directory, for the rest of the VM:

      YmerNode.Script.Harness.put_request_plug(nil)
      YmerNode.Script.Harness.put_secrets_path(Path.join(install, "data/secrets.env"))
      YmerNode.Script.Harness.put_files_dir(Path.join(install, "data/files"))

  Whether the run is set up is the caller's own question: `Process.whereis/1`
  of the name it gave its supervisor, and the getters the keys already have —
  `YmerNode.Secrets.path/0`, `YmerNode.Script.Context.request_options/0` and
  `YmerNode.Script.Context.files_dir/1`.

  None of this is rendered into `scripts guide`: a script never learns where
  its secrets live or what its requests are stubbed with. A script that calls
  this module from inside the node reaches past its context into the node's
  own modules — outside the promise, and acceptance is where a reader sees it.
  """
  alias YmerNode.Script.Context
  alias YmerNode.Secrets

  # The owners whose entries this module points keys in.
  @owners [Context, Secrets]

  @doc """
  The processes a script's run needs when the node's application is not
  running — the throttles' process registry, their supervisor, and the
  compiler's task supervisor — as a child list the caller starts under a
  supervisor of its own, per test or once for a whole run of many. The runner's
  own registry of runs in flight is not in it: that is the node's bookkeeping
  around a run, not part of what a run needs.

  The names are the node's own and VM-global, so a VM starts the list once at a
  time: a second start while the first is up fails at the first child already
  registered — `Supervisor.start_link/3` answers
  `{:error, {:shutdown, {:failed_to_start_child, id, {:already_started, pid}}}}`
  and never attempts the children after it. Inside the node the application has
  already started every one of them.
  """
  def run_tree do
    [
      {Task.Supervisor, name: YmerNode.Scripts.TaskSupervisor},
      {Registry, keys: :unique, name: YmerNode.Scripts.Throttles},
      {DynamicSupervisor, name: YmerNode.Scripts.ThrottleSupervisor, strategy: :one_for_one}
    ]
  end

  @doc """
  Puts `plug` into the Req options the node merges under every script request,
  for the rest of the VM — a stub such as `{Req.Test, YmerNode.Script.Context}`
  for a test, or `nil` to take the plug off, so a live run's requests reach the
  real host. Every other option `YmerNode.Script.Context.request_options/0`
  answers is kept.
  """
  def put_request_plug(nil) do
    put_key(Context, :request_options, Keyword.delete(Context.request_options(), :plug))
  end

  # The four shapes Req runs as a plug: a module, `{module, options}`, and a
  # function of the conn with or without options. A boolean is excluded
  # explicitly: Req reads `plug: false` as no plug and would send the request.
  def put_request_plug(plug)
      when (is_atom(plug) and not is_boolean(plug)) or
             (is_tuple(plug) and tuple_size(plug) == 2 and is_atom(elem(plug, 0))) or
             is_function(plug, 1) or is_function(plug, 2) do
    put_key(Context, :request_options, Keyword.put(Context.request_options(), :plug, plug))
  end

  @doc """
  Points `YmerNode.Secrets` at the file `path` names, expanded to an absolute
  path, for the rest of the VM: every later `YmerNode.Script.Context.secret/2`
  reads it and every `YmerNode.Secrets.set/2` writes it. A test that follows a
  live run in the same VM still cannot write a real file this way:
  `YmerNode.Script.Test.put_secrets/1` refuses any path outside the project's
  `tmp/` before it writes.
  """
  def put_secrets_path(path) when is_binary(path) do
    put_key(Secrets, :path, Path.expand(path))
  end

  @doc """
  Points `YmerNode.Script.Context.files_dir/1` at `directory`, expanded to an
  absolute path, for the rest of the VM. The directory is the caller's to
  create, as the node creates its own at boot.
  """
  def put_files_dir(directory) when is_binary(directory) do
    put_key(Context, :files_dir, Path.expand(directory))
  end

  # The whole entries of both owners whose keys this module points, taken so a
  # caller can put them back as it found them: `restore/1` puts each entry back
  # whole, or deletes it when it was unset, so an unset key stays unset rather
  # than coming back as a default. `configured?/2` asks whether one owner's
  # entry sets one key to a value — a `nil` counts as unset, as it does for
  # `put_request_plug/1`.
  #
  # Public, and `@doc false`, ONLY so `YmerNode.Script.Test` can fill a test's
  # configuration and undo it without reading either owner's entry itself, and
  # so the node's own `YmerNode.ScriptHarnessTest` and
  # `YmerNode.ScriptTestSupportTest` put both entries back the same way: this
  # module stays the one place outside the owners that touches them.
  @doc false
  def snapshot, do: Map.new(@owners, &{&1, Application.get_env(:ymer_node, &1)})

  @doc false
  def restore(saved) when is_map(saved), do: Enum.each(saved, &restore_entry/1)

  @doc false
  def configured?(owner, key) when owner in @owners and is_atom(key) do
    value = :ymer_node |> Application.get_env(owner, []) |> Keyword.get(key)
    value != nil
  end

  defp restore_entry({owner, nil}), do: Application.delete_env(:ymer_node, owner)
  defp restore_entry({owner, config}), do: Application.put_env(:ymer_node, owner, config)

  # One key of an owner's entry, the rest of the entry kept: the files
  # directory and the request options share `YmerNode.Script.Context`'s.
  defp put_key(owner, key, value) do
    config = Application.get_env(:ymer_node, owner, [])
    Application.put_env(:ymer_node, owner, Keyword.put(config, key, value))
  end
end
