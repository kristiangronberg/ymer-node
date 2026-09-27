if Mix.env() in [:dev, :test] do
  defmodule Mix.Tasks.YmerNode.BrowserCheck do
    @moduledoc """
    Runs the browser service's own tests — `node --test` in `browser-service/`,
    against the real Chromium its pinned Playwright drives.

    ## Usage

        mix ymer_node.browser_check

    No options and no arguments. The node's suite tests its side of the wire
    through `Req.Test`, with no browser; these tests are the service's side, so
    `mix precommit` runs both and one gate covers the whole contract.

    ## What it runs

    `npm ci` first, whenever `browser-service/node_modules` is missing or older
    than `package-lock.json` — a fresh clone, or a commit that moved the
    Playwright pin — which installs the locked packages and, through the
    package's `postinstall`, the browser builds they drive. Then `npm test`.
    Neither touches the storage states a person keeps: every test works in a
    directory of its own under the system's temporary directory, and every
    server a test starts listens on a port the system picks.

    It needs Node.js, and refuses by name when `npm` is not on the `PATH`. A
    Playwright whose browser build is missing fails its first test with the
    instruction that fixes it.

    The module is wrapped in `if Mix.env() in [:dev, :test]`, like
    `mix ymer_node.consumer_check`, so a consumer's build of the node never
    contains it.
    """
    use Mix.Task

    alias Mix.Tasks.YmerNode.Build

    @shortdoc "Run the browser service's own tests"

    @impl Mix.Task
    def run([]) do
      npm =
        System.find_executable("npm") ||
          Mix.raise(
            "mix ymer_node.browser_check needs Node.js 20 or later, which ships npm, " <>
              "and none is on this PATH."
          )

      directory = Path.join(File.cwd!(), "browser-service")
      if stale?(directory), do: npm!(npm, ["ci"], directory)
      npm!(npm, ["test"], directory)

      Mix.shell().info([:green, "\n✓ The browser service's own tests pass", :reset])
    end

    def run(argv) do
      Mix.raise("mix ymer_node.browser_check takes no arguments (got: #{Enum.join(argv, " ")})")
    end

    # npm records the tree it installed in node_modules/.package-lock.json, so a
    # lockfile newer than that record means the tree predates the lock. Public
    # only so its test can hand it a directory of its own.
    @doc false
    def stale?(directory) do
      installed = Path.join([directory, "node_modules", ".package-lock.json"])
      locked = Path.join(directory, "package-lock.json")

      not File.exists?(installed) or
        File.stat!(locked, time: :posix).mtime > File.stat!(installed, time: :posix).mtime
    end

    defp npm!(npm, args, directory) do
      command = "npm #{Enum.join(args, " ")}"
      Mix.shell().info([:cyan, "\n==> #{command}", :reset])

      {_output, status} =
        System.cmd(npm, args,
          cd: directory,
          stderr_to_stdout: true,
          into: Build.live_output(:stdio)
        )

      if status != 0,
        do: Mix.raise("#{command} failed in browser-service/ (exit status #{status}).")
    end
  end
end
