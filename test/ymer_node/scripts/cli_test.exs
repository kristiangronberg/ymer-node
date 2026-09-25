defmodule YmerNode.Scripts.CLITest do
  @moduledoc """
  Exercises every verb through `run/2`, which is why there is no release, no
  shell and no terminal anywhere in this file. `main/1` is the only function
  that touches the world — it prints and exits — and it is a thin wrapper over
  `run/2` plus `unpack/1`, both of which are tested directly; the one thing it
  decides for itself, which answer is bytes and which a line, is pinned in the
  export cases through `capture_io`.

  What this file cannot reach is the overlay: that `rel/overlays/bin/ymer-node`
  packs argv the way `unpack/1` expects, and that `exit({:shutdown, n})`
  surfaces as a shell exit status. Both are covered by the documented container
  smoke in the plan, and the packing half is pinned here from the Elixir side —
  a case builds the exact string the shell produces and unpacks it.

  Not async: it writes script rows and points `YmerNode.Secrets` at a file.
  """
  use YmerNode.DataCase

  import ExUnit.CaptureIO

  alias YmerNode.Scripts
  alias YmerNode.Scripts.CLI
  alias YmerNode.Scripts.Compiler
  alias YmerNode.Scripts.Script
  alias YmerNode.Scripts.Throttle
  alias YmerNode.Secrets

  doctest CLI

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    saved = Application.get_env(:ymer_node, Secrets)
    Application.put_env(:ymer_node, Secrets, path: Path.join(tmp_dir, "secrets.env"))

    on_exit(fn ->
      if saved, do: Application.put_env(:ymer_node, Secrets, saved)
    end)

    %{tmp_dir: tmp_dir}
  end

  describe "unpack/1" do
    @tag doc: """
         The exact bytes `printf '%s\\0' "$@" | base64` produces, including the
         trailing NUL the shell leaves on the last argument. A failure means the
         overlay and this function disagree about the encoding — every verb
         would then arrive as an unknown command, and no other case would say so
         because they all build their argv as a list.
         """
    test "reads the shell's NUL-joined, base64'd argv" do
      args = ~s({"name":"req"})

      packed =
        Base.encode64(Enum.join(["scripts", "run", "hex", "package", args], <<0>>) <> <<0>>)

      assert CLI.unpack(packed) == ["scripts", "run", "hex", "package", args]
    end

    test "survives an argument that would break a quoted expression" do
      hostile = "a\"b\#{:erlang.halt()}c"

      assert CLI.unpack(Base.encode64(hostile <> <<0>>)) == [hostile]
    end

    test "answers an empty list for no arguments and for junk" do
      assert CLI.unpack("") == []
      assert CLI.unpack("not base64 at all!!") == []
    end
  end

  describe "scripts list" do
    test "says so when there is nothing, and how to change that" do
      assert {output, 0} = CLI.run(["scripts", "list"])
      assert output =~ "No scripts"
      assert output =~ "scripts import"
    end

    test "marks each script's state and names its actions" do
      import!(segment())

      assert {output, 0} = CLI.run(["scripts", "list"])
      assert output =~ "ok    "
      assert output =~ "fetch, ping"
    end

    @tag doc: """
         An unaccepted script is listed, marked, and not hidden. Hiding it would
         leave an operator with a script the node holds, refuses to run, and
         never mentions — the exact state the whole acceptance design exists to
         make visible.
         """
    test "marks an unaccepted script rather than hiding it" do
      script = import!(segment())

      script
      |> Script.changeset(%{accepted_hash: "stale"})
      |> Repo.update!()

      assert {output, 0} = CLI.run(["scripts", "list"])
      assert output =~ "unacc "
      assert output =~ script.name
    end
  end

  describe "scripts describe" do
    test "renders the write mark, the required arguments and the declarations" do
      script = import!(segment())

      assert {output, 0} = CLI.run(["scripts", "describe", script.name])
      assert output =~ "read  fetch(url)"
      assert output =~ "read  ping()"
      assert output =~ "declarations:"
      refute output =~ "defmodule"
    end

    test "carries the code only when it is asked for" do
      script = import!(segment())

      assert {output, 0} = CLI.run(["scripts", "describe", script.name, "--code"])
      assert output =~ "defmodule Script."
    end

    test "refuses a script that is not there, with status 1" do
      assert {output, 1} = CLI.run(["scripts", "describe", "absent"])
      assert output =~ "no script named absent"
    end
  end

  describe "scripts export" do
    test "answers exactly the code the node holds" do
      segment = segment()
      script = import!(segment)

      assert {code, 0} = CLI.run(["scripts", "export", script.name])
      assert code == code(segment)
    end

    @tag doc: """
         The round trip the verb exists for: exported bytes imported into a
         node land at the same hash, so a script moves between nodes unchanged.
         A failure means export added or lost a byte — a rendering, a newline —
         and `import < file` on the other side would accept different code.
         """
    test "round-trips through import at the same hash" do
      segment = segment()
      script = import!(segment)
      {code, 0} = CLI.run(["scripts", "export", script.name])
      {:ok, _removed} = Scripts.remove(script.name)

      assert {_output, 0} = CLI.run(["scripts", "import"], fn -> code end)
      assert {:ok, imported} = Scripts.get(script.name)
      assert imported.code_hash == script.code_hash
    end

    test "refuses a script that is not there, with status 1" do
      assert {output, 1} = CLI.run(["scripts", "export", "absent"])
      assert output =~ "no script named absent"
    end

    @tag doc: """
         `main/1` prints every answer with a newline except this one: the code
         goes out as bytes, so `> file` holds what the node holds. The control
         is `scripts list`, whose answer keeps its newline. A failure on the
         export half means a trailing byte reaches every file an operator
         exports; on the control half, that every other verb lost its line end.
         """
    test "main writes the export as bytes and every other answer as a line" do
      segment = segment()
      script = import!(segment)

      exported =
        capture_io(fn -> catch_exit(CLI.main(packed(["scripts", "export", script.name]))) end)

      listed = capture_io(fn -> catch_exit(CLI.main(packed(["scripts", "list"]))) end)

      assert exported == code(segment)
      assert String.ends_with?(listed, "\n")
    end

    @tag doc: """
         The other half of "bytes and nothing else": the release's logger level.
         Unpinned, a release logs at `:debug` and Ecto's query lines print into
         the operator's terminal beside the answer — an import's INSERT carrying
         the whole script. Read off `config/prod.exs` the way `YmerNode.McpTest`
         reads the bind, because this environment's config is never the
         release's.
         """
    test "the release pins the logger level, so nothing rides the export's stdout" do
      release_config =
        Config.Reader.read!(Path.expand("../../../config/prod.exs", __DIR__), env: :prod)

      assert release_config |> Keyword.fetch!(:logger) |> Keyword.fetch!(:level) == :info
    end
  end

  describe "scripts import" do
    @tag doc: """
         The file's bytes arrive on stdin, so
         `docker exec -i <c> ymer-node scripts import < file` needs no path
         inside the container. The path form below is the other door — a path
         on the node's own filesystem, which is where the shipped example lives.
         """
    test "reads the code from stdin when no file is given" do
      segment = segment()
      purge_on_exit(segment)

      assert {output, 0} = CLI.run(["scripts", "import"], fn -> code(segment) end)
      assert output =~ "Imported #{Macro.underscore(segment)}"
      assert {:ok, stored} = Scripts.get(Macro.underscore(segment))
      assert stored.origin == "imported"
    end

    @tag doc: """
         `docker exec` without `-i` closes stdin, and what arrives is an empty
         string. Compiled, that is refused with a diagnostic about code the
         node never received, sending the operator to edit a file that is
         fine; the usage error names the slip instead.
         """
    test "refuses an import with nothing on stdin, naming the -i" do
      assert {output, 2} = CLI.run(["scripts", "import"], fn -> "" end)
      assert output =~ "Nothing arrived on stdin"
      assert output =~ "docker exec -i"
      assert Scripts.list() == []
    end

    test "reads the file and stores it, with origin imported", %{tmp_dir: tmp_dir} do
      segment = segment()
      path = Path.join(tmp_dir, "script.exs")
      File.write!(path, code(segment))
      purge_on_exit(segment)

      assert {output, 0} = CLI.run(["scripts", "import", path])
      assert output =~ "Imported #{Macro.underscore(segment)}"
      assert {:ok, stored} = Scripts.get(Macro.underscore(segment))
      assert stored.origin == "imported"
    end

    @tag doc: """
         A missing file is the OPERATOR's mistake, so status 2, not 1. The two
         are kept apart so a script driving this can tell "I typed the path
         wrong" from "the node refused what I asked" — retrying helps with
         neither, but only one is worth reporting as a node problem.
         """
    test "a missing file is a usage error, with status 2", %{tmp_dir: tmp_dir} do
      assert {output, 2} = CLI.run(["scripts", "import", Path.join(tmp_dir, "nope.exs")])
      assert output =~ "Cannot read"
    end

    test "forwards the compiler's refusal with status 1", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "bad.exs")
      File.write!(path, "defmodule Script.Bare do\nend\n")

      assert {output, 1} = CLI.run(["scripts", "import", path])
      assert output =~ "missing_contract"
    end
  end

  describe "scripts run" do
    test "prints the action's result as JSON" do
      script = import!(segment())

      assert {output, 0} = CLI.run(["scripts", "run", script.name, "ping"])
      assert JSON.decode!(output) == %{"pong" => true}
    end

    test "takes a JSON object of arguments" do
      script = import!(segment())
      args = ~s({"url":"https://hex.pm"})

      assert {output, 0} = CLI.run(["scripts", "run", script.name, "fetch", args])
      assert JSON.decode!(output) == %{"url" => "https://hex.pm"}
    end

    test "a non-object or unparseable args string is a usage error" do
      script = import!(segment())

      assert {output, 2} = CLI.run(["scripts", "run", script.name, "fetch", "[1,2]"])
      assert output =~ "must be a JSON object"

      assert {_output, 2} = CLI.run(["scripts", "run", script.name, "fetch", "{oops"])
    end

    test "forwards the runner's refusal with status 1" do
      script = import!(segment())

      assert {output, 1} = CLI.run(["scripts", "run", script.name, "fetch"])
      assert output =~ "invalid_args"
    end
  end

  describe "scripts accept and remove" do
    test "accept marks stale code accepted again" do
      script = import!(segment())

      script
      |> Script.changeset(%{accepted_hash: "stale"})
      |> Repo.update!()

      assert {output, 0} = CLI.run(["scripts", "accept", script.name])
      assert output =~ "Accepted #{script.name}"
    end

    test "remove deletes it" do
      script = import!(segment())

      assert {output, 0} = CLI.run(["scripts", "remove", script.name])
      assert output =~ "Removed #{script.name}"
      assert {:error, _reason} = Scripts.get(script.name)
    end

    test "remove names the schedules that went with it" do
      script = import!(segment())

      for name <- ["morning-report", "weekly-summary"] do
        {:ok, _entry} =
          YmerNode.Schedules.add(%{
            name: name,
            script: script.name,
            action: "ping",
            cron_expression: "0 7 * * *"
          })
      end

      assert {output, 0} = CLI.run(["scripts", "remove", script.name])

      assert output ==
               "Removed #{script.name} and its 2 schedules: morning-report, weekly-summary"
    end
  end

  describe "secrets" do
    @tag doc: """
         The value arrives through the stdin function and never as an argument.
         An argument is visible in `ps` to every user on the machine and in the
         shell's history to this one — which is the whole reason this verb reads
         stdin rather than taking one more word.
         """
    test "set takes its value from stdin, not from argv" do
      assert {output, 0} = CLI.run(["secrets", "set", "JIRA_TOKEN"], fn -> "s3cret\n" end)
      assert output == "Set JIRA_TOKEN"
      assert Secrets.get("JIRA_TOKEN") == {:ok, "s3cret"}
    end

    @tag doc: """
         The sharper half of the closed-stdin slip: an empty value passes the
         value check, is stored as `NAME=`, and a run then presents an empty
         credential to the remote — a 401 with nothing pointing at the missing
         `-i`. An operator wanting no value has `unset`, so refusing is
         unambiguous.
         """
    test "refuses a set with nothing on stdin rather than storing an empty value" do
      assert {output, 2} = CLI.run(["secrets", "set", "EMPTY"], fn -> "" end)
      assert output =~ "Nothing arrived on stdin"
      refute match?({:ok, _value}, Secrets.get("EMPTY"))
    end

    test "list names them and never their values" do
      CLI.run(["secrets", "set", "A"], fn -> "value-a" end)
      CLI.run(["secrets", "set", "B"], fn -> "value-b" end)

      assert {output, 0} = CLI.run(["secrets", "list"])
      assert output =~ "A"
      assert output =~ "B"
      refute output =~ "value-a"
      refute output =~ "value-b"
    end

    test "says so when there are none" do
      assert {output, 0} = CLI.run(["secrets", "list"])
      assert output =~ "No secrets set."
    end

    test "unset removes one" do
      CLI.run(["secrets", "set", "A"], fn -> "value-a" end)

      assert {"Unset A", 0} = CLI.run(["secrets", "unset", "A"])
      assert Secrets.get("A") == {:error, :secret_not_found}
    end

    test "refuses an invalid name with status 1" do
      assert {output, 1} = CLI.run(["secrets", "set", "not a name"], fn -> "x" end)
      assert output =~ "invalid_secret_name"
    end
  end

  describe "throttles" do
    test "list shows a started throttle's tokens, rate, waiters and breaker" do
      name = "cli-#{System.unique_integer([:positive])}"
      throttle = %{rate: 60, burst: 2, breaker: %{threshold: 3, cooldown: 60_000}}
      :ok = Throttle.take(name, throttle, System.monotonic_time(:millisecond) + 1_000)

      assert {output, 0} = CLI.run(["throttles", "list"])

      assert output =~
               ~r/#{name}  1\.\d of 2 tokens at 60\/min  0 waiting  breaker closed, 0 of 3 401s/
    end

    test "list marks an open breaker with the time it has left" do
      name = "cli-#{System.unique_integer([:positive])}"
      throttle = %{rate: 60, burst: 2, breaker: %{threshold: 1, cooldown: 60_000}}
      :ok = Throttle.take(name, throttle, System.monotonic_time(:millisecond) + 1_000)
      Throttle.record(name, 401)

      assert {output, 0} = CLI.run(["throttles", "list"])
      assert output =~ ~r/#{name}  .* breaker OPEN, resumes in 60s/
    end

    test "list shows no breaker column for a throttle declared without one" do
      name = "cli-#{System.unique_integer([:positive])}"
      throttle = %{rate: 60, burst: 2}
      :ok = Throttle.take(name, throttle, System.monotonic_time(:millisecond) + 1_000)

      assert {output, 0} = CLI.run(["throttles", "list"])
      assert output =~ ~r/#{name}  1\.\d of 2 tokens at 60\/min  0 waiting$/m
    end

    @tag doc: """
         The one case that does not go through `run/2`: the node's throttles
         are VM-wide, so once any case has started one, the list `run/2` reads
         is never empty again, and the empty answer is read from the rendering
         alone.
         """
    test "list answers a node with no throttle started, at status 0" do
      assert {"No throttle has started on this node.", 0} = CLI.render_throttles([])
    end

    test "reset closes an open breaker, at status 0" do
      name = "cli-#{System.unique_integer([:positive])}"
      throttle = %{rate: 60, burst: 2, breaker: %{threshold: 1, cooldown: 60_000}}
      :ok = Throttle.take(name, throttle, System.monotonic_time(:millisecond) + 1_000)
      Throttle.record(name, 401)

      assert {"Reset " <> ^name, 0} = CLI.run(["throttles", "reset", name])
      assert [%{breaker: %{resumes_in: nil}}] = Enum.filter(Throttle.list(), &(&1.name == name))
    end

    test "reset refuses a name no request has started, at status 1" do
      name = "cli-#{System.unique_integer([:positive])}"

      assert {output, 1} = CLI.run(["throttles", "reset", name])
      assert output == "throttle_not_started: no throttle #{name} has started on this node"
    end
  end

  describe "schedules" do
    test "list says there are none, naming the verb that adds one" do
      assert {output, 0} = CLI.run(["schedules", "list"])
      assert output =~ "No schedules. Add one with: ymer-node schedules add"
    end

    test "add answers the next firing and the end, and list shows the schedule" do
      script = import!(segment())

      assert {added, 0} =
               CLI.run(["schedules", "add", "morning-report", script.name, "ping", "0 7 * * *"])

      assert added =~ "Added morning-report: next firing "
      assert added =~ ", ends "

      assert {listed, 0} = CLI.run(["schedules", "list"])
      assert listed =~ "active  morning-report  #{script.name} ping {}"
      assert listed =~ "    0 7 * * *  next "
      assert listed =~ "    no run yet"
    end

    test "add takes --args as a JSON object and --lifetime" do
      script = import!(segment())

      argv = [
        "schedules",
        "add",
        "fetcher",
        script.name,
        "fetch",
        "@daily",
        "--args",
        ~s({"url":"https://hex.pm"}),
        "--lifetime",
        "P30D"
      ]

      assert {_added, 0} = CLI.run(argv)
      assert {listed, 0} = CLI.run(["schedules", "list"])
      assert listed =~ ~s(fetch {"url":"https://hex.pm"})
    end

    test "a bad --args or an unknown option is a usage error" do
      script = import!(segment())
      add = ["schedules", "add", "fetcher", script.name, "fetch", "@daily"]

      assert {output, 2} = CLI.run(add ++ ["--args", "[1]"])
      assert output =~ "must be a JSON object"

      assert {output, 2} = CLI.run(add ++ ["--every", "hour"])
      assert output =~ "Unrecognised options"
    end

    test "forwards the node's refusal with status 1" do
      script = import!(segment())

      assert {output, 1} = CLI.run(["schedules", "add", "short", script.name, "ping", "* * *"])
      assert output =~ "invalid_cron_expression"
    end

    test "update changes the cron expression, and remove deletes the schedule" do
      script = import!(segment())

      {_added, 0} =
        CLI.run(["schedules", "add", "morning-report", script.name, "ping", "0 7 * * *"])

      assert {updated, 0} =
               CLI.run(["schedules", "update", "morning-report", "--cron", "30 8 * * *"])

      assert updated =~ "Updated morning-report"

      assert {listed, 0} = CLI.run(["schedules", "list"])
      assert listed =~ "    30 8 * * *  next "

      assert {"Removed morning-report", 0} = CLI.run(["schedules", "remove", "morning-report"])
      assert {output, 1} = CLI.run(["schedules", "remove", "morning-report"])
      assert output =~ "not_found"
    end
  end

  describe "usage" do
    test "help lists every verb, at status 0" do
      assert {output, 0} = CLI.run(["help"])

      for verb <- [
            "scripts list",
            "scripts import",
            "scripts export",
            "secrets set",
            "scripts run",
            "schedules list",
            "schedules add",
            "throttles list",
            "throttles reset"
          ] do
        assert output =~ verb
      end
    end

    test "no arguments and an unknown verb both print usage, at status 2" do
      assert {usage, 2} = CLI.run([])
      assert usage =~ "ymer-node"

      assert {output, 2} = CLI.run(["scripts", "frobnicate"])
      assert output =~ "Unknown command: scripts frobnicate"
      assert output =~ "ymer-node"
    end
  end

  defp segment, do: "Cli#{System.unique_integer([:positive])}"

  # The exact bytes the overlay hands `main/1`: NUL-joined, trailing NUL, base64.
  defp packed(argv), do: Base.encode64(Enum.join(argv, <<0>>) <> <<0>>)

  defp purge_on_exit(segment) do
    on_exit(fn -> Compiler.purge(Module.concat(["Script", segment])) end)
  end

  defp import!(segment) do
    purge_on_exit(segment)
    {:ok, script} = Scripts.import(code(segment))
    script
  end

  defp code(segment) do
    """
    defmodule Script.#{segment} do
      use YmerNode.Script

      @impl true
      def description, do: "the #{segment} script"

      @impl true
      def actions do
        %{
          fetch: %{
            description: "fetches a url",
            properties: %{"url" => %{"type" => "string"}},
            required: ["url"],
            write: false
          },
          ping: %{description: "answers", properties: %{}, write: false}
        }
      end

      @impl true
      def declarations, do: %{hosts: [], url_action: nil, secrets: []}

      @impl true
      def run(:ping, _args, _context), do: {:ok, %{"pong" => true}}
      def run(:fetch, %{"url" => url}, _context), do: {:ok, %{"url" => url}}
    end
    """
  end
end
