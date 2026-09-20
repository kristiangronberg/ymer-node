if Mix.env() in [:dev, :test] do
  # Remediation(removable: Elixir's `IO.stream/2` no longer raises on a chunk
  # boundary that falls inside a multi-byte codepoint): the stdlib collectable
  # writes each raw port chunk straight to a unicode device, and
  # `Mix.Shell.IO.cmd/2` carries the identical defect, so neither can carry a
  # subprocess whose output is not pure ASCII.
  # plan: 2026-09-05-docker-output-streaming
  defmodule Mix.Tasks.YmerNode.Build.LiveOutput do
    @moduledoc """
    A subprocess's output reaching the terminal as it is produced — faithful
    for valid UTF-8, with anything unreadable shown as `�`, and unable to stop
    the task that runs it, whatever bytes it carries.

    The port hands `System.cmd/3`'s collectable flat 65536-byte chunks, so a
    boundary falls wherever the byte count lands — regularly inside one of the
    box-drawing characters a compiler diagnostic is framed with. The device
    those bytes go to is a unicode one, and stays one when stdout is redirected
    to a file, so half a codepoint reaching it raises instead of printing.
    `IO.stream/2`'s second argument is no lever against that: `:line` and a
    byte count alike shape the read direction only, and the collectable it
    returns writes every chunk it is handed straight to the device whichever
    one is passed — so the line-at-a-time framing that argument suggests was
    never real, and tuning it was never a fix.

    This collectable therefore never presents an incomplete or invalid sequence
    to the device. It holds back a trailing sequence the bytes so far still
    allow to be a codepoint — at most three bytes — and prepends it to the next
    chunk; a sequence a byte has already ruled out has its first byte written
    as `�` and the remainder re-split behind it. Nothing else is read out of
    the bytes: no lines, no escape sequences, no assumption about what the
    subprocess prints. That is what keeps a carriage-return progress redraw on
    screen as it arrives, where a collectable buffering by line shows docker's
    fast layers once, at the end.

    What it collects must be iodata: `System.cmd/3` opens its port with
    `:binary`, so that is what it is handed. Chardata is not accepted, and the
    narrowing is silent rather than loud — a codepoint list is read as bytes,
    so codepoints 128–255 come out as `�` and anything larger raises in
    `IO.iodata_to_binary/1`.

    The device is a field rather than a fixed `:stdio` because a `StringIO`
    enforces the same encoding: a test can prove the property against one
    without capturing the run's own output.
    """

    defstruct [:device]

    defimpl Collectable do
      def into(live_output) do
        {{live_output, ""}, &collect/2}
      end

      # `IO.iodata_to_binary/1` also flattens, and the `:error` clause below
      # relies on it: `:unicode.characters_to_binary/3` returns the unreadable
      # rest as a binary only when it was handed one.
      defp collect({live_output, held}, {:cont, data}) do
        {live_output, write(live_output.device, held <> IO.iodata_to_binary(data))}
      end

      defp collect({live_output, held}, :done) do
        replace_held(live_output.device, held)
        live_output
      end

      defp collect(_accumulator, :halt), do: :ok

      defp write(device, data), do: write(device, data, [])

      # The accumulator is what keeps a run of unreadable bytes to one write.
      # Emitting per fragment costs a synchronous round trip to the device for
      # every byte replaced, so a chunk that is mostly not UTF-8 — a build step
      # dumping a binary — would spend tens of thousands of them and read as a
      # stall. `unwind/2` keeps the ordinary all-valid chunk a bare binary — and
      # an empty one the `""` that `emit/2` skips.
      defp write(device, data, accumulator) do
        case :unicode.characters_to_binary(data, :utf8, :utf8) do
          binary when is_binary(binary) ->
            emit(device, unwind(accumulator, binary))
            ""

          {:incomplete, readable, truncated} ->
            emit(device, unwind(accumulator, readable))
            truncated

          {:error, readable, <<_unreadable, rest::binary>>} ->
            write(device, rest, ["�", readable | accumulator])
        end
      end

      defp unwind([], binary), do: binary
      defp unwind(accumulator, binary), do: Enum.reverse([binary | accumulator])

      defp emit(_device, ""), do: :ok
      defp emit(device, iodata), do: IO.write(device, iodata)

      # Nothing can complete a held sequence once the output has ended, so what
      # was held is unreadable by then and takes the same per-byte rule.
      defp replace_held(device, held), do: emit(device, String.duplicate("�", byte_size(held)))
    end
  end

  defmodule Mix.Tasks.YmerNode.Build do
    @moduledoc """
    Build the release image and tag it with the commit it was built from.

    ## Usage

        mix ymer_node.build

    No options and no arguments. The version comes from `mix.exs`, the image is
    built for the machine's own architecture, and three tags move to it: the
    version, `latest`, and the revision — the short sha of the commit the build
    was made from, marked when the tree carried uncommitted changes. That same
    revision rides on the image's OCI revision label and inside the node's own
    `serverInfo.version`, so `docker images`, the label, and a live `initialize`
    all name one commit. Where no revision can be named — no `git`, or a
    directory that is no work tree — the image gets the version tag and `latest`
    only, carries no label, and answers with the bare version.

    ## What moves `ymer-node:latest`

    `docker-compose.yml` runs that tag and never builds it, so no compose `up`
    moves it. Only a build does — this task, or a plain
    `docker build -t ymer-node:latest .` for a reader without Elixir — or a
    deliberate `docker tag`, which is how an older image is put back under the
    name compose reads. A container picks the new image up on the next
    `docker compose up -d`, and `mix ymer_node.deploy` is what performs that
    against the install.

    ## Keeping the image set in hand

    A revision tag is minted per commit built, so revision tags accumulate
    where the version tag and `latest` merely move. Nothing here deletes any of
    them. Trimming is a judgement about which builds are still worth going back
    to — yours to make, not a build's — so the commands live here, beside the
    code that mints the tags, rather than running on their own.

    What has accumulated, with the dates to judge it by. Read the dates rather
    than the order: this listing is not sorted by creation time, and it prints
    it only to the second.

        docker images ymer-node --format '{{.Tag}} {{.ID}} {{.CreatedAt}}'

    Which containers exist and what image each is on — the check to make before
    removing anything, since a container may be the only thing still holding an
    image:

        docker ps -a --format '{{.Names}} {{.Image}} {{.Status}}'

    Dropping one revision tag. Without `-f`, so Docker itself is the safety
    net: it removes a tag from an image that has others, and refuses outright
    to delete an image's last tag while any container — running or stopped —
    still uses it.

        docker rmi ymer-node:<revision>

    Whether superseded images linger at all depends on the image store.
    Measured on Docker's containerd store (`docker info` names it): moving
    every tag off an image reclaims it there and then, so nothing is left to
    prune. On a storage driver that does leave them, `docker image prune`
    removes what no tag names.

    ## What stops the build, and what only warns

    A missing `docker`, a daemon that does not answer, and a non-zero build all
    stop with a message naming the next action. A dirty working tree does not:
    the revision records the dirt instead, refusing would block every
    build-to-test cycle, and tagging only some of the tags would make the tag
    set depend on state the caller never passed. The warning says the image will
    carry uncommitted code, and the build proceeds. Where the check itself
    cannot run — no `git`, or a directory that is no work tree — the task says
    so in one line and still builds.

    The subprocess's own output never stops a build either, whatever bytes it
    carries: `Mix.Tasks.YmerNode.Build.LiveOutput` is where that is kept.

    A build that dies inside `mix deps.get` usually means the network intercepts
    TLS, so hex's certificate no longer chains. This image carries no company
    certificate by design (the `Dockerfile` header says why), so the failure
    message names that case; the network itself is never probed.

    The module is wrapped in `if Mix.env() in [:dev, :test]`, which keeps it
    callable under the default `:dev` and out of the prod release — the release
    runs the image this task builds and has no use for the builder.
    """
    use Mix.Task

    alias Mix.Tasks.YmerNode.Build.LiveOutput

    @shortdoc "Build the Ymer Node release image"

    @image "ymer-node"
    @revision_arg "YMER_NODE_REVISION"
    @revision_label "org.opencontainers.image.revision"

    @dirty_warning "Warning: the working tree is dirty — the image will carry uncommitted code."
    @dirty_unknown "Note: could not check whether the working tree is clean; building anyway."

    @next_step "`mix ymer_node.deploy` deploys it to the install."

    @doc """
    Fail unless `docker` is on PATH and its daemon answers, and return the
    project root.

    Public because `mix ymer_node.deploy` refuses on the same two conditions
    before it does anything else; one home for the checks beats two that drift.
    Both entry points call it, and `build!/0` deliberately does not — a deploy
    would otherwise pay for a second `docker info`.
    """
    def preflight! do
      root = File.cwd!()

      unless System.find_executable("docker") do
        Mix.raise("`docker` was not found on PATH. Install Docker and retry.")
      end

      unless docker_answers?(["info"]) do
        Mix.raise("The Docker daemon is not answering. Start your Docker daemon and retry.")
      end

      root
    end

    @doc """
    The OCI label key a build stamps the revision on.

    Public because `mix ymer_node.deploy` reads the same key back off the
    install's container to find out which revision it was running. One home for
    the key means a rename cannot leave the reader silently finding nothing.
    """
    def revision_label, do: @revision_label

    @doc """
    The revision a build stamps on its image: the short sha of the commit it was
    made from, marked when the tree carried uncommitted changes. `nil` where
    there is no sha to name, and the image then carries no revision at all.

    Successive dirty builds of one commit re-point that one tag, the way
    `latest` moves.

    ## Examples

        iex> Mix.Tasks.YmerNode.Build.revision("b2a7152", :clean)
        "b2a7152"

        iex> Mix.Tasks.YmerNode.Build.revision("b2a7152", :dirty)
        "b2a7152-dirty"

        iex> Mix.Tasks.YmerNode.Build.revision(nil, :unknown)
        nil

    """
    def revision(short_sha, tree_state)
        when is_binary(short_sha) and tree_state in [:clean, :dirty] do
      if tree_state == :dirty, do: "#{short_sha}-dirty", else: short_sha
    end

    def revision(_short_sha, _tree_state), do: nil

    @doc """
    The tags a build applies: the version tag, `latest`, and the revision tag
    where a revision could be named. The revision tag is the only one that names
    a commit rather than a position, so it is the one that accumulates.

    ## Examples

        iex> Mix.Tasks.YmerNode.Build.image_tags("3.4.5", "b2a7152")
        ["ymer-node:3.4.5", "ymer-node:latest", "ymer-node:b2a7152"]

        iex> Mix.Tasks.YmerNode.Build.image_tags("1.2.3", nil)
        ["ymer-node:1.2.3", "ymer-node:latest"]

    """
    def image_tags(version, revision) when is_binary(version) do
      stable = ["#{@image}:#{version}", "#{@image}:latest"]

      if revision, do: stable ++ ["#{@image}:#{revision}"], else: stable
    end

    @doc """
    The `docker` arguments a build runs.

    A revision rides twice — as the build argument the runtime stage turns into
    an environment variable, and as the OCI revision label — so the label, the
    tag and the running node's `serverInfo.version` cannot disagree. Without
    one, neither argument appears: an empty label would claim a revision the
    image does not have, and an empty environment variable would leave the wire
    version ending in a separator with nothing after it.

    ## Examples

        iex> Mix.Tasks.YmerNode.Build.build_argv(["ymer-node:1.2.3"], nil)
        ["build", "-t", "ymer-node:1.2.3", "."]

        iex> argv = Mix.Tasks.YmerNode.Build.build_argv(["ymer-node:1.2.3"], "b2a7152")
        iex> Enum.take(argv, 3)
        ["build", "--build-arg", "YMER_NODE_REVISION=b2a7152"]

    """
    def build_argv(tags, revision) when is_list(tags) do
      ["build"] ++ revision_args(revision) ++ Enum.flat_map(tags, &["-t", &1]) ++ ["."]
    end

    @doc """
    Whether the working tree at `root` is clean, dirty, or unreadable — the
    state half of `tree_status/1`, for a caller with no use for the listing.

    `build!/0` warns on it. `mix ymer_node.deploy` does not borrow it: its
    dirty-tree refusal prints the listing, so it reads `tree_status/1`
    instead.
    """
    def tree_state(root) when is_binary(root), do: elem(tree_status(root), 0)

    @doc """
    The tree's state with the `git status --porcelain` listing that decided
    it — `""` for `:clean` and `:unknown`. `mix ymer_node.deploy` prints the
    listing under its dirty-tree refusal, from the one read that classified,
    so what it lists is what the refusal was decided on.
    """
    def tree_status(root) when is_binary(root) do
      if System.find_executable("git"), do: git_tree_status(root), else: {:unknown, ""}
    end

    @doc """
    Whether `docker` answers the given arguments with a zero exit.

    Public for the same one-home reason as `preflight!/0`, `tree_status/1` and
    `revision_label/0`: `mix ymer_node.deploy` asks the same question of the
    compose plugin and of a revision tag, and two copies would drift into
    judging "docker answered" differently.
    """
    def docker_answers?(args) when is_list(args) do
      match?({_output, 0}, System.cmd("docker", args, stderr_to_stdout: true))
    end

    @doc """
    A `Mix.Tasks.YmerNode.Build.LiveOutput` over `device`. Pass it as
    `System.cmd/3`'s `:into`.

    Public because `mix ymer_node.deploy` streams compose's output through the
    same collectable; one home for how a subprocess reaches the terminal beats
    two that drift.

    ## Examples

        iex> Mix.Tasks.YmerNode.Build.live_output(:stdio)
        %Mix.Tasks.YmerNode.Build.LiveOutput{device: :stdio}

    """
    def live_output(device) when is_atom(device) or is_pid(device) do
      %LiveOutput{device: device}
    end

    @doc """
    Build the image and apply its tags. Returns the version, the revision —
    `nil` where none could be named — and the tags applied.

    That return is what `mix ymer_node.deploy` needs: the tags to report, and
    the revision to compose the wire version it then holds the running
    container to. Callers run `preflight!/0` first.
    """
    def build! do
      root = File.cwd!()
      tree_state = tree_state(root)
      warn_tree(tree_state)

      version = Mix.Project.config()[:version]
      revision = revision(short_sha(root), tree_state)
      tags = image_tags(version, revision)

      docker_build!(build_argv(tags, revision), root)

      %{version: version, revision: revision, tags: tags}
    end

    @impl Mix.Task
    def run([]) do
      preflight!()
      built = build!()

      Mix.shell().info([:green, "\n✓ Built #{Enum.join(built.tags, " + ")}", :reset])
      Mix.shell().info("  Next: " <> @next_step)
    end

    def run(argv) do
      Mix.raise("mix ymer_node.build takes no arguments (got: #{Enum.join(argv, " ")})")
    end

    # cwd is the project root by construction: Mix resolves a task defined in
    # this project's `lib/` only after loading `mix.exs` from cwd, so a call
    # made from elsewhere never reaches these functions — it dies earlier, in
    # Mix's own task lookup.
    defp revision_args(nil), do: []

    defp revision_args(revision) do
      [
        "--build-arg",
        "#{@revision_arg}=#{revision}",
        "--label",
        "#{@revision_label}=#{revision}"
      ]
    end

    defp warn_tree(:clean), do: :ok
    defp warn_tree(:dirty), do: warn(@dirty_warning)
    defp warn_tree(:unknown), do: warn(@dirty_unknown)

    defp git_tree_status(root) do
      case System.cmd("git", ["status", "--porcelain"], cd: root) do
        {"", 0} -> {:clean, ""}
        {output, 0} -> {:dirty, output}
        {_output, _status} -> {:unknown, ""}
      end
    end

    defp short_sha(root) do
      if System.find_executable("git"), do: git_short_sha(root), else: nil
    end

    # stdout only: this output becomes the revision, and so the tag, the OCI
    # label and the wire version. Merged, anything git writes to stderr while
    # still exiting 0 — a wrapper's notice, a hook's warning — is trimmed into
    # the sha and stamped as if it were one, which Docker accepts silently.
    defp git_short_sha(root) do
      args = ["rev-parse", "--short", "HEAD"]

      case System.cmd("git", args, cd: root) do
        {output, 0} -> String.trim(output)
        {_output, _status} -> nil
      end
    end

    defp docker_build!(args, root) do
      Mix.shell().info([:cyan, "\n==> docker #{Enum.join(args, " ")}", :reset])

      {_output, status} =
        System.cmd("docker", args,
          cd: root,
          stderr_to_stdout: true,
          into: live_output(:stdio)
        )

      if status != 0, do: Mix.raise(build_failure_message(status))
    end

    defp build_failure_message(status) do
      """
      docker build failed (exit status #{status}).

      If it died inside `mix deps.get`, the network is intercepting TLS and hex's
      certificate no longer chains. This image carries no company certificate by
      design — build it off that network.
      """
    end

    defp warn(message) do
      Mix.shell().info([:yellow, message, :reset])
    end
  end
end
