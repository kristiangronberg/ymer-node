defmodule YmerNode.Scripts.CLI do
  @moduledoc """
  The operator's verbs, run on the machine the node runs on — the node's own
  human door, beside the client's approval.

  A worker reaches scripts through MCP. A person reaches them through here, and
  the two doors exist for different reasons: importing a file from a repository,
  setting a secret whose value must never travel through a model's context,
  resetting a throttle's breaker, which no session may reset, and looking at
  what a node holds when no client is connected are all things the wire is the
  wrong shape for.

  ## How it arrives

  There is no escript and no separate binary. `rel/overlays/bin/ymer-node` is a
  shell script the release carries, and every verb is one `bin/ymer_node rpc`
  into the running node — so the CLI talks to the node that is *already serving*
  rather than booting a second VM against the same database. Two VMs on one
  SQLite file is the thing this arrangement exists to avoid.

  The overlay is named `ymer-node` with a hyphen, and that is not cosmetic:
  overlays are copied over the release **last**, so an overlay named
  `ymer_node` would silently replace the release's own launcher.

  ## The argv seam

  `rpc` takes an Elixir expression as a string, so the shell's arguments have to
  survive being pasted into one. They are packed by the overlay — NUL-joined,
  then base64 — and `main/1` unpacks them. Nothing an operator types can then
  close a quote or inject an expression, which a naive interpolation would
  allow for any argument carrying a double quote or an interpolation marker.

  ## Where an imported file is read

  `scripts import` with no argument reads the file from **stdin** — the rpc'd
  process inherits the caller's group leader, so `docker exec -i <container>
  ymer-node scripts import < file` crosses the container boundary with no path
  inside it. `scripts import <file>` reads a path on the node's own filesystem
  instead, which is where the shipped example lives; a host path given there is
  refused with status 2, because the node cannot see it.

  Nothing on stdin — `docker exec` without `-i` — is a usage error, status 2,
  for `import` and for `secrets set` alike. What arrives then is an empty string,
  which would otherwise be compiled as an empty script and refused with a
  diagnostic about code that never came, or stored as an empty secret that a
  run then presents to the remote as a credential.

  ## Talking back

  Everything goes to **stdout**. A process started by `rpc` has the calling
  shell as its group leader, so `IO.puts/1` reaches the operator's terminal —
  but `IO.puts(:stderr, …)` does not: stderr belongs to the *node's* process,
  wherever that was started, so a message written there is lost. That is why
  refusals are printed rather than logged, and why the exit code carries the
  verdict.

  Exit status is `exit({:shutdown, status})`, which is the one channel `rpc`
  propagates: `0` for a verb that did what it said, `1` for a refusal the node
  made, `2` for a usage error the operator made.

  One verb prints bytes rather than a line: `scripts export <name>` writes the
  code the node holds and nothing else — not even the newline every other
  answer ends with — so `> file` holds exactly those bytes and a
  `scripts import` of that file on another node lands the same hash. Its
  refusal is a line like any other. The release pins the logger level at
  `:info` (`config/prod.exs`) so no query log rides that stdout: unpinned, a
  release logs at `:debug`, and Ecto's query lines then print into the
  operator's terminal beside the answer — an import's INSERT carrying the
  whole script.

  ## Testing shape

  `main/1` is the only function that touches the world. `run/2` takes an argv
  list and a function that supplies stdin, and answers `{output, status}` — so
  every verb is exercised without a release, a shell or a terminal, which is
  what the whole rest of this module's tests do.
  """
  alias YmerNode.Scripts
  alias YmerNode.Scripts.Throttle
  alias YmerNode.Secrets

  @doc """
  The entry point the overlay calls: unpacks argv, runs the verb, prints, exits.

  Takes the base64 of the NUL-joined arguments. Exits rather than returning,
  because the exit status is how a shell learns what happened.
  """
  def main(packed) when is_binary(packed) do
    argv = unpack(packed)
    {output, status} = run(argv)

    print(argv, output, status)
    exit({:shutdown, status})
  end

  # An export that succeeded is bytes; every other answer is a line — the
  # moduledoc's § Talking back.
  defp print(["scripts", "export" | _rest], code, 0), do: IO.write(code)
  defp print(_argv, output, _status), do: IO.puts(output)

  @doc """
  Unpacks the overlay's argv encoding — base64 of the NUL-joined arguments.

  ## Examples

      iex> YmerNode.Scripts.CLI.unpack(Base.encode64("scripts\\0list\\0"))
      ["scripts", "list"]

      iex> YmerNode.Scripts.CLI.unpack("")
      []

  """
  def unpack(packed) when is_binary(packed) do
    case Base.decode64(packed) do
      {:ok, joined} -> String.split(joined, <<0>>, trim: true)
      :error -> []
    end
  end

  @doc """
  Runs one verb, answering `{output, status}`.

  `stdin` is a function so a test can supply a value without a terminal; the
  default reads the operator's own stdin, which is how `secrets set` takes a
  value that must never appear in a process list.
  """
  def run(argv, stdin \\ &read_stdin/0)

  def run(["scripts", "list"], _stdin), do: scripts_list()
  def run(["scripts", "describe", name], _stdin), do: describe(name, false)
  def run(["scripts", "describe", name, "--code"], _stdin), do: describe(name, true)
  def run(["scripts", "export", name], _stdin), do: export(name)
  def run(["scripts", "import"], stdin), do: from_stdin(stdin, "the script", &import_code/1)
  def run(["scripts", "import", path], _stdin), do: import_file(path)

  # Remediation(permanent): `push` was this verb's name before it became
  # `import`, and programs written against the old name call it still. These
  # two clauses answer exactly as `import` does — the same statuses, the same
  # line, the same origin — and `usage/0` names only `import`.
  # plan: 2026-09-23-scripts-program-door
  def run(["scripts", "push"], stdin), do: run(["scripts", "import"], stdin)
  def run(["scripts", "push", path], stdin), do: run(["scripts", "import", path], stdin)

  def run(["scripts", "accept", name], _stdin), do: accept(name)
  def run(["scripts", "remove", name], _stdin), do: remove(name)
  def run(["scripts", "run", name, action], _stdin), do: run_action(name, action, "{}")
  def run(["scripts", "run", name, action, args], _stdin), do: run_action(name, action, args)

  def run(["secrets", "list"], _stdin), do: secrets_list()

  def run(["secrets", "set", name], stdin),
    do: from_stdin(stdin, "the value", &secret_set(name, &1))

  def run(["secrets", "unset", name], _stdin), do: secret_unset(name)

  def run(["throttles", "list"], _stdin), do: throttles_list()
  def run(["throttles", "reset", name], _stdin), do: throttle_reset(name)

  def run(["help"], _stdin), do: {usage(), 0}
  def run([], _stdin), do: {usage(), 2}
  def run(argv, _stdin), do: {"Unknown command: #{Enum.join(argv, " ")}\n\n" <> usage(), 2}

  # ─── scripts ────────────────────────────────────────────────────────

  defp scripts_list do
    case Scripts.list() do
      [] -> {"No scripts. Import one with: ymer-node scripts import < file", 0}
      scripts -> {Enum.map_join(scripts, "\n", &list_line/1), 0}
    end
  end

  defp list_line(script) do
    actions = script.actions |> Enum.sort() |> Enum.map_join(", ", &Atom.to_string/1)
    "#{state(script)} #{script.name}  #{script.description}\n    #{actions}"
  end

  # A single glyph per row, because a listing is scanned rather than read. Only
  # the third needs explaining, and `describe` is where its diagnostics are.
  defp state(%{accepted?: true, loaded?: true}), do: "ok    "
  defp state(%{accepted?: false}), do: "unacc "
  defp state(_broken), do: "BROKEN"

  defp describe(name, code?) do
    case Scripts.describe(name, code: code?) do
      {:ok, script} -> {render_describe(script), 0}
      {:error, reason} -> refusal(reason)
    end
  end

  defp render_describe(script) do
    [
      "#{script.name} — #{script.description}",
      "  origin: #{script.origin}   contract: #{script.contract}",
      "  accepted: #{script.accepted?}   compiled: #{script.loaded?}",
      "  declarations: #{inspect(script.declarations)}",
      render_actions(script.actions),
      render_trouble(script),
      render_code(script)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp render_actions(actions) when map_size(actions) == 0, do: ""

  defp render_actions(actions) do
    "  actions:\n" <> Enum.map_join(Enum.sort(actions), "\n", &action_line/1)
  end

  defp action_line({name, schema}) do
    mark = if schema.write, do: "WRITE", else: "read "
    required = schema |> Map.get(:required, []) |> Enum.join(", ")
    "    #{mark} #{name}(#{required}) — #{schema.description}"
  end

  defp render_trouble(%{error: nil}), do: ""
  defp render_trouble(%{error: {reason, detail}}), do: "  will not run: #{reason} — #{detail}"

  defp render_code(%{code: nil}), do: ""
  defp render_code(%{code: code}), do: "\n" <> code

  # The row's bytes and nothing else; `main/1` writes them without a newline.
  defp export(name) do
    case Scripts.get(name) do
      {:ok, script} -> {script.code, 0}
      {:error, reason} -> refusal(reason)
    end
  end

  # Both doors land here; where each reads the file is the moduledoc's § Where
  # an imported file is read. Not `import/1`: that name, called unqualified,
  # is `Kernel.SpecialForms.import/2`.
  defp import_code(code), do: written(Scripts.import(code), "Imported")

  defp import_file(path) do
    case File.read(path) do
      {:ok, code} -> import_code(code)
      {:error, posix} -> {"Cannot read #{path}: #{:file.format_error(posix)}", 2}
    end
  end

  defp accept(name), do: written(Scripts.accept(name), "Accepted")

  defp remove(name) do
    case Scripts.remove(name) do
      {:ok, script} -> {"Removed #{script.name}", 0}
      {:error, reason} -> refusal(reason)
    end
  end

  defp written({:ok, script}, verb), do: {"#{verb} #{script.name}", 0}
  defp written({:error, reason}, _verb), do: refusal(reason)

  defp run_action(name, action, args) do
    with {:ok, decoded} <- decode_args(args),
         {:ok, result} <- Scripts.run(name, action, decoded) do
      {JSON.encode!(result), 0}
    else
      {:error, {:bad_json, message}} -> {"args must be a JSON object: #{message}", 2}
      {:error, reason} -> refusal(reason)
    end
  end

  defp decode_args(args) do
    case JSON.decode(args) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, other} -> {:error, {:bad_json, "got #{inspect(other)}"}}
      {:error, reason} -> {:error, {:bad_json, inspect(reason)}}
    end
  end

  # ─── secrets ────────────────────────────────────────────────────────

  # A missing file and an empty file are one answer here. `YmerNode.Secrets`
  # distinguishes them because a *read* of a named secret needs to — "not set"
  # and "nothing is set" are different faults to chase — but an operator asking
  # what is set on a machine where nothing ever was should be told "none", not
  # handed an error about a file they were never supposed to create by hand.
  defp secrets_list do
    case Secrets.list() do
      {:ok, []} -> {"No secrets set.", 0}
      {:ok, names} -> {Enum.join(names, "\n"), 0}
      {:error, :secrets_file_missing} -> {"No secrets set.", 0}
      {:error, reason} -> refusal(reason)
    end
  end

  # The value arrives on stdin and never as an argument: an argument is visible
  # in `ps` to every user on the machine, and in the shell's history to this one.
  defp secret_set(name, value) do
    case Secrets.set(name, String.trim_trailing(value, "\n")) do
      :ok -> {"Set #{name}", 0}
      {:error, reason} -> refusal(reason)
    end
  end

  defp secret_unset(name) do
    case Secrets.unset(name) do
      :ok -> {"Unset #{name}", 0}
      {:error, reason} -> refusal(reason)
    end
  end

  # Empty stdin is a usage error and never a value (moduledoc § Where an
  # imported file is read): the one operator slip that produces it is
  # `docker exec` without `-i`, so the message names that.
  defp from_stdin(stdin, what, verb) do
    case stdin.() do
      "" ->
        {"Nothing arrived on stdin for #{what}. Pipe it in — `docker exec -i`, not `docker exec`.",
         2}

      value ->
        verb.(value)
    end
  end

  defp read_stdin do
    case IO.read(:stdio, :eof) do
      value when is_binary(value) -> value
      _no_value -> ""
    end
  end

  # ─── throttles ──────────────────────────────────────────────────────

  defp throttles_list, do: render_throttles(Throttle.list())

  # A throttle exists once a request has named it, so an empty list is a node
  # nothing has asked to throttle yet, not a fault.
  #
  # Public, and `@doc false`, ONLY so that empty answer is testable: the node's
  # throttles are VM-wide, so the list is never empty again once any case has
  # started one. `YmerNode.Scripts.CLITest` is the reader.
  @doc false
  def render_throttles([]), do: {"No throttle has started on this node.", 0}
  def render_throttles(throttles), do: {Enum.map_join(throttles, "\n", &throttle_line/1), 0}

  defp throttle_line(throttle) do
    tokens = :erlang.float_to_binary(throttle.tokens, decimals: 1)
    bucket = "#{tokens} of #{throttle.burst} tokens at #{throttle.rate}/min"

    "#{throttle.name}  #{bucket}  #{throttle.waiters} waiting#{breaker_text(throttle.breaker)}"
  end

  defp breaker_text(nil), do: ""

  defp breaker_text(%{resumes_in: nil} = breaker),
    do: "  breaker closed, #{breaker.failures} of #{breaker.threshold} 401s"

  defp breaker_text(%{resumes_in: resumes_in}),
    do: "  breaker OPEN, resumes in #{div(resumes_in + 999, 1_000)}s"

  # The human's door and nobody else's: the breaker stops a changed password from
  # locking an account, and a session able to reset it would reset it against
  # that very failure.
  defp throttle_reset(name) do
    case Throttle.reset(name) do
      :ok -> {"Reset #{name}", 0}
      {:error, reason} -> refusal(reason)
    end
  end

  # ─── shared ─────────────────────────────────────────────────────────

  # Status 1, never 2: a refusal is the node declining something the operator
  # asked for correctly, and a script that branches on the two needs them apart.
  defp refusal({reason, detail}), do: {"#{reason}: #{detail}", 1}
  defp refusal(reason), do: {inspect(reason), 1}

  defp usage do
    """
    ymer-node — operator verbs for the node running on this machine

      scripts list
      scripts describe <name> [--code]
      scripts export <name>       the code, exactly as the node holds it
      scripts import              the file on stdin
      scripts import <file>       a path on the node's own filesystem
      scripts accept <name>
      scripts remove <name>
      scripts run <name> <action> [json-args]

      secrets list
      secrets set <NAME>          value on stdin, never as an argument
      secrets unset <NAME>

      throttles list              the throttles this node has started
      throttles reset <name>      close an open breaker and clear its count

    Every verb runs against the node already serving on this machine.\
    """
  end
end
