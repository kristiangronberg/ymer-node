if Mix.env() in [:dev, :test] do
  defmodule Mix.Tasks.YmerNode.ConsumerCheck do
    @moduledoc """
    Proves the way a script author's own repository takes the node: a project
    depending on this checkout under `runtime: false`, where none of the
    node's applications start, tests a script through `YmerNode.Script.Test`
    and starts the run tree through `YmerNode.Script.Harness`.

    ## Usage

        mix ymer_node.consumer_check

    No options and no arguments. The node's own suite cannot prove this: it
    boots the node's application, so the run tree is up in every test there,
    and a setup that starts it raises instead — `start_supervised!/1` fails
    loudly on the collision rather than returning a value.

    ## What it runs

    The fixture project is committed under `consumer_check/` — its
    configuration, its tests, and one script that declares a throttle and a
    secret — and every run copies it fresh into `_build/consumer_check/project`,
    beside a `mix.exs` this task writes: the node by path under
    `runtime: false`, and Req for runtime, the shape a consumer's own project
    takes. The `mix.exs` is written here rather than committed, so the only
    project file in the repository that carries a version is the node's own.

    The copy takes this checkout's `mix.lock`, so it resolves to exactly the
    versions the node is built with, and reads its dependencies from this
    checkout's `deps/` (`MIX_DEPS_PATH`): once `mix deps.get` has run here, the
    fixture's own `deps.get` downloads no package, though it still resolves
    against the hex registry. It builds under
    `_build/consumer_check/build` (`MIX_BUILD_ROOT`), so the node it compiles
    is its own and never this checkout's build.

    The fixture's `mix` runs on the Elixir and Erlang this task runs on — their
    `bin` directories lead its `PATH` — so it never depends on how the shell
    resolves a toolchain for a directory with no configuration of its own.
    `MIX_TEST_PARTITION` is unset for it, so its tests read the unpartitioned
    names under its own `tmp/`.

    Not part of `mix precommit`: a run compiles the node and every dependency
    into the fixture's build, about twenty seconds on a first run.

    The module is wrapped in `if Mix.env() in [:dev, :test]`, like
    `mix ymer_node.build`, so a consumer's build of the node — dependencies
    compile under `:prod` — never contains it.
    """
    use Mix.Task

    alias Mix.Tasks.YmerNode.Build

    @shortdoc "Test the script test support from a consumer project"

    @mix_exs """
    defmodule ConsumerCheck.MixProject do
      use Mix.Project

      def project do
        [
          app: :consumer_check,
          version: "0.0.0",
          deps: [
            {:ymer_node, path: System.fetch_env!("YMER_NODE_PATH"), runtime: false},
            {:req, "~> 0.7"}
          ]
        ]
      end

      def application, do: [extra_applications: [:logger]]
    end
    """

    @impl Mix.Task
    def run([]) do
      root = File.cwd!()
      work = Path.join([root, "_build", "consumer_check"])
      project = Path.join(work, "project")

      File.rm_rf!(project)
      File.mkdir_p!(work)
      File.cp_r!(Path.join(root, "consumer_check"), project)
      File.cp!(Path.join(root, "mix.lock"), Path.join(project, "mix.lock"))
      File.write!(Path.join(project, "mix.exs"), @mix_exs)

      environment = environment(root, work)
      mix!(["deps.get"], project, environment)
      mix!(["test"], project, environment)

      Mix.shell().info([:green, "\n✓ A consumer project tests a script through the node", :reset])
    end

    def run(argv) do
      Mix.raise("mix ymer_node.consumer_check takes no arguments (got: #{Enum.join(argv, " ")})")
    end

    defp environment(root, work) do
      [
        {"YMER_NODE_PATH", root},
        {"MIX_DEPS_PATH", Path.join(root, "deps")},
        {"MIX_BUILD_ROOT", Path.join(work, "build")},
        {"MIX_ENV", "test"},
        {"MIX_TEST_PARTITION", nil},
        {"MIX_BUILD_PATH", nil},
        {"MIX_EXS", nil},
        {"PATH", Enum.join([elixir_bin(), erlang_bin(), System.get_env("PATH", "")], ":")}
      ]
    end

    defp elixir_bin, do: Path.expand("../../bin", Application.app_dir(:elixir))

    defp erlang_bin, do: Path.join(to_string(:code.root_dir()), "bin")

    defp mix!(args, project, environment) do
      command = "mix #{Enum.join(args, " ")}"
      Mix.shell().info([:cyan, "\n==> #{command}", :reset])

      {_output, status} =
        System.cmd(Path.join(elixir_bin(), "mix"), args,
          cd: project,
          env: environment,
          stderr_to_stdout: true,
          into: Build.live_output(:stdio)
        )

      if status != 0, do: Mix.raise("#{command} failed in #{project} (exit status #{status}).")
    end
  end
end
