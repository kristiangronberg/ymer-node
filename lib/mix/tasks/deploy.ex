if Mix.env() in [:dev, :test] do
  defmodule Mix.Tasks.YmerNode.Deploy do
    @moduledoc """
    Deploy: move the checkout's committed `main` into the install — name the
    rollback target, build, carry the compose file, recreate the install's
    container on the image, and verify it came up on it.

    ## Usage

        mix ymer_node.deploy

    No options and no arguments. It deploys into the
    [*install*](docs/glossary.md#install), found through
    `YMER_NODE_INSTALL_DIR` and defaulting to `~/Apps/ymer-node`. Making the
    first install is not this task's job — the README's hand steps make one,
    and this task moves new code into one that already exists.

    ```mermaid
    sequenceDiagram
        autonumber
        participant Task as mix ymer_node.deploy
        participant Git as git, in the checkout
        participant Docker as docker
        participant Compose as compose, in the install
        participant Node as the node

        Task->>Docker: docker info
        Task->>Git: tree state, current branch
        Task->>Compose: ps -q
        Note over Task,Compose: every refusal lands before anything changes
        Task->>Compose: ps -a -q
        Task->>Docker: the container's revision label
        Task->>Docker: does the revision's tag still resolve?
        Task->>Docker: point previous at that revision
        Task->>Docker: build and tag
        Task->>Task: copy docker-compose.yml into the install
        Task->>Compose: up -d
        Task->>Docker: container image id
        Task->>Node: server/discover
        Node-->>Task: serverInfo.version
    ```

    ## What it refuses, and why the order is load-bearing

    A deploy stops before it changes anything when `docker` is missing or its
    daemon is silent, when the working tree is dirty or unreadable, when the
    checkout is not on `main`, when the install resolves inside the checkout,
    when the install holds no compose file or holds one compose would read
    instead of it, and when the install's container is still running — or when
    compose cannot say whether it is. Each refusal names the next action.

    Two of those orderings are not cosmetic. The compose-file check must
    precede the running check: compose resolves its file by walking up parent
    directories, so `ps -q` in a directory without one silently answers for an
    ancestor's project — from anywhere under the checkout that is the
    checkout's own project, empty, and indistinguishable from an install that
    is not running. And the install-path check must precede the compose-file
    check, because the checkout does hold a compose file: the file check would
    pass, and `up -d` would create the install's container in the checkout's
    project against the checkout's `./data`. That comparison resolves the
    install to its physical directory first — expanding `~` and `..` leaves a
    symlink in place, and the checkout root arrives already resolved — so an
    install reached through a link into the checkout is refused too, and the
    refusal then names the directory the link points at rather than the one
    that was configured.

    The running check reads `ps -q` in the install directory, so compose
    resolves the project from the install's own `.env` and no name resolution
    is re-implemented here. A container id means running and the deploy
    refuses; empty means stopped, crashed, or absent, all of which `up -d`
    recreates. A crash-looping container lists as running, which is right — it
    should be stopped by hand before new code lands on it. A `ps -q` that fails
    outright is neither: compose could not answer, which is not the same as
    answering that nothing is up, so the deploy refuses there too rather than
    recreating a container that may still be live. That is the one refusal a
    deploy takes on a reading it could not make, and it is deliberate — the
    reading it stands in for is the one that keeps a live node from being
    recreated under a session.

    The refusal names `stop`, not `down`. After `stop` the container and its
    labels stay and `up -d` recreates it on the new image, so a deploy that
    fails before `up -d` leaves the old node one `start` away, untouched. After
    `down` the old container is gone, and a downed install reads the same as
    one that was never started.

    ## The rollback target

    `ymer-node:previous` names the revision the install ran *before* the last
    deploy, so going back needs no lookup and no sha typed out. The README's
    "Running it" carries the two commands that use it.

    It is pointed before the build, not after, and that order is the whole
    reason it works. This machine's image store reclaims an image the moment
    its last tag moves away, so a deploy of the revision the install is already
    running would otherwise reclaim the very image being named: the tag has to
    be in place before `docker build` moves anything. With `previous` holding
    it, a rebuild of that same revision leaves the old image alone; without it,
    the old image is gone by the time anything could name it.

    The revision is read off the install's *container*, not off an image
    record, because a container keeps its image's labels after that record has
    been reclaimed — which is often the only reason the revision can still be
    named at all. The container is stopped by the time this runs, the running
    check having passed, so `ps -a -q` is what finds it; `ps -q` is empty.

    Four states name nothing, and each is reported rather than stopping the
    deploy: compose could not say what containers the install has, no container
    at all (the install was taken down), a container carrying no revision label
    (it was built before the label existed), and a revision whose
    `ymer-node:<revision>` tag has since been removed. A missing rollback
    target is information, not a refusal — the running check above refuses when
    compose cannot answer because a wrong reading there recreates a live
    container, while a wrong reading here only leaves a tag unset.

    `previous` names code, not a particular build. Rebuilding one commit mints
    a fresh image id under that same revision tag, so after a hand rebuild
    between deploys the tag resolves to different bytes — of the same source,
    which is what a rollback is reaching for.

    ## What it proves before it says the node is up

    Two checks, in order. The container's image id — `{{.Image}}`, the id, not
    the reference it was created from — must equal the id `ymer-node:latest`
    now names; a reference compare would read the same for a container that
    never moved. Then a `server/discover` on the port Docker reports published
    must answer a `serverInfo.version` equal to the version and revision just
    built. The port comes from `docker port` rather than from any assumption
    here, and a container found `restarting`, `exited` or `dead` fails fast
    with its state and restart count rather than waiting out the budget.

    The node's supervision tree brings its HTTP listener up last, so a
    `server/discover` that answers is also proof that the store opened and the
    vector extension loaded.

    ## What a deploy does not touch

    The store: `data/` is a bind mount the recreate keeps, and
    `server/discover` is a read. The install's `.env` — install-specific
    state, and theirs. And the version in `mix.exs`, which is a release
    number, not a build's identity; the revision is what names the code.

    The module is wrapped in `if Mix.env() in [:dev, :test]`, which keeps it
    callable under the default `:dev` and out of the prod release.
    """
    use Mix.Task

    alias Mix.Tasks.YmerNode.Build

    @shortdoc "Deploy the built image to the install"

    @image "ymer-node"
    @previous_tag "previous"
    @compose_file "docker-compose.yml"
    @shadowing_compose_files ~w(compose.yaml compose.yml)
    @install_dir_env "YMER_NODE_INSTALL_DIR"
    @default_install_dir "~/Apps/ymer-node"
    @protocol_version "2026-07-28"
    @serverinfo_field "io.modelcontextprotocol/serverInfo"

    # The node boots in seconds — the listener is its last child, and the only
    # work in front of it is the node database's migrator, which runs the
    # repo's own migrations against a local SQLite file — so this budget is a
    # wide margin, not a model of how long a boot takes. A first boot on a cold
    # bind mount is the slowest case, since it creates node.db and applies every
    # migration before the listener binds. It bounds elapsed time, not probes —
    # to within one probe's own timeout, since the deadline is read between
    # probes: counting probes instead would let a listener that accepts and
    # never answers stretch the wait several-fold.
    @readiness_budget_ms 20_000
    @readiness_interval_ms 1_000
    @dead_container_states ~w(restarting exited dead)

    @doc """
    Where the install is, as configured — the `YMER_NODE_INSTALL_DIR` value, or
    the default where that is unset or blank. Left unexpanded: the caller
    expands it, so the value stays printable in a refusal exactly as it was
    written.

    ## Examples

        iex> Mix.Tasks.YmerNode.Deploy.install_dir_setting(nil)
        "~/Apps/ymer-node"

        iex> Mix.Tasks.YmerNode.Deploy.install_dir_setting("   ")
        "~/Apps/ymer-node"

        iex> Mix.Tasks.YmerNode.Deploy.install_dir_setting("/opt/ymer-node")
        "/opt/ymer-node"

    """
    def install_dir_setting(nil), do: @default_install_dir

    def install_dir_setting(value) when is_binary(value) do
      case String.trim(value) do
        "" -> @default_install_dir
        trimmed -> trimmed
      end
    end

    @doc """
    The Compose spelling this machine answers to: the v2 subcommand wherever
    the plugin is installed, the standalone binary only where the plugin is
    missing and the binary is present. A machine with neither gets the v2
    spelling, which is the one worth installing.

    ## Examples

        iex> Mix.Tasks.YmerNode.Deploy.compose_spelling(true, false)
        "docker compose"

        iex> Mix.Tasks.YmerNode.Deploy.compose_spelling(false, true)
        "docker-compose"

        iex> Mix.Tasks.YmerNode.Deploy.compose_spelling(false, false)
        "docker compose"

    """
    def compose_spelling(v2_answers?, standalone_on_path?)
        when is_boolean(v2_answers?) and is_boolean(standalone_on_path?) do
      if standalone_on_path? and not v2_answers?, do: "docker-compose", else: "docker compose"
    end

    @doc """
    A spelling split into the executable and arguments `System.cmd/3` needs.
    The v2 spelling is two words, one of which is a subcommand rather than a
    program — printing it and running it are different jobs.

    ## Examples

        iex> Mix.Tasks.YmerNode.Deploy.compose_argv("docker compose", ["ps", "-q"])
        {"docker", ["compose", "ps", "-q"]}

        iex> Mix.Tasks.YmerNode.Deploy.compose_argv("docker-compose", ["ps", "-q"])
        {"docker-compose", ["ps", "-q"]}

    """
    def compose_argv(spelling, args) when is_binary(spelling) and is_list(args) do
      [executable | prefix] = String.split(spelling, " ", trim: true)

      {executable, prefix ++ args}
    end

    @doc """
    Whether the working tree lets a deploy name what it ships. Build only warns
    on a dirty tree; a deploy refuses, because the revision it stamps is the
    only claim the running node can make about its own code.

    ## Examples

        iex> Mix.Tasks.YmerNode.Deploy.tree_refusal(:clean)
        :ok

        iex> {:refuse, message} = Mix.Tasks.YmerNode.Deploy.tree_refusal(:dirty)
        iex> String.contains?(message, "Commit, stash or remove")
        true

        iex> {:refuse, message} = Mix.Tasks.YmerNode.Deploy.tree_refusal(:unknown)
        iex> String.contains?(message, "needs git and a work tree")
        true

    """
    def tree_refusal(:clean), do: :ok

    def tree_refusal(:dirty) do
      {:refuse,
       "The working tree is dirty, so a revision would not name what is deployed. " <>
         "Commit, stash or remove what is listed above, then rerun mix ymer_node.deploy."}
    end

    def tree_refusal(:unknown) do
      {:refuse,
       "Could not read the working tree's state, so no revision can be named. " <>
         "A deploy needs git and a work tree; mix ymer_node.build does not."}
    end

    @doc """
    Whether the checkout is on the branch a deploy ships.

    ## Examples

        iex> Mix.Tasks.YmerNode.Deploy.branch_refusal("main")
        :ok

        iex> {:refuse, message} = Mix.Tasks.YmerNode.Deploy.branch_refusal("topic")
        iex> String.contains?(message, "Switch to main")
        true

    """
    def branch_refusal("main"), do: :ok

    def branch_refusal(branch) when is_binary(branch) do
      {:refuse,
       "A deploy ships main, and this checkout is on #{branch}. " <>
         "Switch to main, then rerun mix ymer_node.deploy."}
    end

    @doc """
    Whether the install sits outside the checkout. Inside it — the root itself,
    or anything below it — the checkout's own compose file would satisfy every
    later check, and `up -d` would create the install's container in the
    checkout's project against the checkout's `./data`.

    ## Examples

        iex> Mix.Tasks.YmerNode.Deploy.install_path_refusal("/opt/node", "/src/node")
        :ok

        iex> {:refuse, _} = Mix.Tasks.YmerNode.Deploy.install_path_refusal("/src/node", "/src/node")
        iex> {:refuse, _} = Mix.Tasks.YmerNode.Deploy.install_path_refusal("/src/node/x", "/src/node")
        iex> :matched
        :matched

    """
    def install_path_refusal(install_dir, checkout_root)
        when is_binary(install_dir) and is_binary(checkout_root) do
      inside? =
        install_dir == checkout_root or
          String.starts_with?(install_dir, checkout_root <> "/")

      if inside? do
        {:refuse,
         "The install directory #{install_dir} is the checkout, or inside it. " <>
           "Point #{@install_dir_env} at a directory outside this checkout."}
      else
        :ok
      end
    end

    @doc """
    Whether a file compose would read instead of `docker-compose.yml` sits
    beside it in the install. Compose resolves its file by name in a fixed
    order — `compose.yaml`, then `compose.yml`, then `docker-compose.yml` — so
    one of the first two in the install would be the file every compose
    command here runs, while the file the deploy checks for and carries is the
    third. The deploy refuses rather than pinning `-f`: a pin would drop the
    override file compose merges on its own, and would make the commands the
    refusals name run against a different file than the task did.

    ## Examples

        iex> Mix.Tasks.YmerNode.Deploy.compose_shadow_refusal("/opt/node", [])
        :ok

        iex> {:refuse, message} = Mix.Tasks.YmerNode.Deploy.compose_shadow_refusal("/opt/node", ["compose.yaml"])
        iex> String.contains?(message, "compose.yaml")
        true

    """
    def compose_shadow_refusal(_install_dir, []), do: :ok

    def compose_shadow_refusal(install_dir, shadows)
        when is_binary(install_dir) and is_list(shadows) do
      {:refuse,
       "#{install_dir} holds #{Enum.join(shadows, " and ")}, which compose reads " <>
         "instead of #{@compose_file}, so the file this deploy carries would not be " <>
         "the one it runs. Remove or rename it, then rerun mix ymer_node.deploy."}
    end

    @doc """
    Whether the install holds a compose file. It must, and this has to be
    answered before anything asks compose about the install's project: compose
    walks up to a parent's file when a directory has none, and would then
    answer for the wrong project entirely.

    ## Examples

        iex> Mix.Tasks.YmerNode.Deploy.compose_file_refusal("/opt/node", true)
        :ok

        iex> {:refuse, message} = Mix.Tasks.YmerNode.Deploy.compose_file_refusal("/opt/node", false)
        iex> String.contains?(message, "/opt/node")
        true

    """
    def compose_file_refusal(_install_dir, true), do: :ok

    def compose_file_refusal(install_dir, false) when is_binary(install_dir) do
      {:refuse,
       "No #{@compose_file} in #{install_dir}. A deploy carries the file into an " <>
         "install that already runs the node; the README's \"Running it\" makes " <>
         "the first one. Set #{@install_dir_env} if the install is elsewhere."}
    end

    @doc """
    What `ps -q` in the install said about its container, read from that
    command's output and its exit status. Compose printing nothing on a clean
    exit is an answer — the container is stopped, crashed, or was never
    created — but a non-zero exit is not one: compose could not answer at all,
    and reading that as "nothing is up" is how a deploy recreates a container
    that is still live.

    ## Examples

        iex> Mix.Tasks.YmerNode.Deploy.compose_running_state("abc123\\n", 0)
        :running

        iex> Mix.Tasks.YmerNode.Deploy.compose_running_state("  \\n", 0)
        :not_running

        iex> Mix.Tasks.YmerNode.Deploy.compose_running_state("no configuration file", 1)
        :unknown

    """
    def compose_running_state(output, 0) when is_binary(output) do
      if String.trim(output) == "", do: :not_running, else: :running
    end

    def compose_running_state(output, status) when is_binary(output) and is_integer(status) do
      :unknown
    end

    @doc """
    Whether the install's container is stopped enough to deploy onto. The
    argument is `compose_running_state/2`'s reading, and `:not_running` is the
    only one that proceeds: a stopped, crashed or never-created container is
    what `up -d` recreates. A crash-looping container reads `:running`, which
    is right — it should be stopped by hand before new code lands on it — and
    `:unknown` refuses like a running one, since the deploy cannot tell them
    apart and only one of the two is safe to recreate.

    ## Examples

        iex> Mix.Tasks.YmerNode.Deploy.running_refusal("/opt/node", "dc", :not_running)
        :ok

        iex> refusal = Mix.Tasks.YmerNode.Deploy.running_refusal("/opt/node", "dc", :running)
        iex> {:refuse, message} = refusal
        iex> String.contains?(message, "`dc stop`")
        true

        iex> {:refuse, message} = Mix.Tasks.YmerNode.Deploy.running_refusal("/o", "dc", :unknown)
        iex> String.contains?(message, "`dc ps -q`")
        true

    """
    def running_refusal(_install_dir, _spelling, :not_running), do: :ok

    def running_refusal(install_dir, spelling, :running)
        when is_binary(install_dir) and is_binary(spelling) do
      {:refuse,
       "The install's container is running in #{install_dir}. Stop it first: " <>
         "`#{spelling} stop` in that directory, then rerun mix ymer_node.deploy."}
    end

    def running_refusal(install_dir, spelling, :unknown)
        when is_binary(install_dir) and is_binary(spelling) do
      {:refuse,
       "Could not tell whether the install's container is running: " <>
         "`#{spelling} ps -q` failed in #{install_dir}, and any output it produced " <>
         "is above. Run it there to see why, then rerun mix ymer_node.deploy."}
    end

    @doc """
    The rollback target a deploy can name, decided from what the install's
    container says. `previous` is re-pointed only when all three hold: the
    install has a container, that container carries a revision label, and a tag
    for that revision is still in the image store. Anything else is skipped
    with the reason, because failing to name a rollback target is information
    rather than a reason to stop.

    The arguments are the three readings, in the order they are taken: the
    container id `ps -a -q` printed — empty where the install has none,
    `:unreadable` where compose could not answer — the revision on that
    container's OCI label (empty where it carries none), and whether
    `ymer-node:<revision>` still resolves.

    ## Examples

        iex> Mix.Tasks.YmerNode.Deploy.rollback_target("abc123", "b2a7152", true)
        {:tag, "b2a7152"}

        iex> {:skip, reason} = Mix.Tasks.YmerNode.Deploy.rollback_target(:unreadable, "", false)
        iex> String.contains?(reason, "could not read")
        true

        iex> {:skip, reason} = Mix.Tasks.YmerNode.Deploy.rollback_target("", "", false)
        iex> String.contains?(reason, "no container")
        true

        iex> {:skip, reason} = Mix.Tasks.YmerNode.Deploy.rollback_target("abc123", "", false)
        iex> String.contains?(reason, "no revision label")
        true

        iex> {:skip, reason} = Mix.Tasks.YmerNode.Deploy.rollback_target("abc", "b2a7152", false)
        iex> String.contains?(reason, "ymer-node:b2a7152")
        true

    """
    def rollback_target(:unreadable, _revision, _tag_present?) do
      {:skip, "compose could not read the install's containers, so none was named"}
    end

    def rollback_target("", _revision, _tag_present?) do
      {:skip, "the install had no container, so no revision could be read"}
    end

    def rollback_target(_container, "", _tag_present?) do
      {:skip, "the install's container carries no revision label"}
    end

    def rollback_target(_container, revision, false) when is_binary(revision) do
      {:skip, "#{@image}:#{revision} is gone, so nothing is left to point at"}
    end

    def rollback_target(_container, revision, true) when is_binary(revision) do
      {:tag, revision}
    end

    @doc """
    The close's line for what the rollback target turned out to be — the tag it
    now names, or the reason nothing was named.

    ## Examples

        iex> Mix.Tasks.YmerNode.Deploy.rollback_line({:named, "b2a7152"})
        "Rollback target: ymer-node:previous now names ymer-node:b2a7152."

        iex> Mix.Tasks.YmerNode.Deploy.rollback_line({:skip, "the install had no container"})
        "Rollback target: none — the install had no container."

    """
    def rollback_line({:named, revision}) when is_binary(revision) do
      "Rollback target: #{@image}:#{@previous_tag} now names #{@image}:#{revision}."
    end

    def rollback_line({:skip, reason}) when is_binary(reason) do
      "Rollback target: none — #{reason}."
    end

    @doc """
    The version string a container built from this version and revision answers
    on `server/discover` — semver build metadata, composed the same way
    `config/runtime.exs` composes it inside the release. A build with no
    revision answers the bare version.

    ## Examples

        iex> Mix.Tasks.YmerNode.Deploy.wire_version("1.2.3", "b2a7152")
        "1.2.3+b2a7152"

        iex> Mix.Tasks.YmerNode.Deploy.wire_version("1.2.3", nil)
        "1.2.3"

    """
    def wire_version(version, nil) when is_binary(version), do: version

    def wire_version(version, revision) when is_binary(version) and is_binary(revision) do
      "#{version}+#{revision}"
    end

    @doc """
    The host port Docker reports published for a container, read from `docker
    port` output rather than assumed. A stopped container publishes nothing and
    prints nothing, which is `:error` here.

    ## Examples

        iex> Mix.Tasks.YmerNode.Deploy.published_port("8012/tcp -> 127.0.0.1:8012")
        {:ok, 8012}

        iex> Mix.Tasks.YmerNode.Deploy.published_port("")
        :error

    """
    def published_port(output) when is_binary(output) do
      output
      |> String.split("\n", trim: true)
      |> Enum.find_value(:error, &port_in_line/1)
    end

    @doc """
    The `serverInfo.version` in a `server/discover` response body, where it
    rides in the result's `_meta` under `io.modelcontextprotocol/serverInfo`.
    The node answers as plain JSON, so nothing here unwraps an event stream.

    ## Examples

        iex> body = ~s({"result":{"_meta":{"io.modelcontextprotocol/serverInfo":{"version":"1.2.3+b2a7152"}}}})
        iex> Mix.Tasks.YmerNode.Deploy.serverinfo_version(body)
        {:ok, "1.2.3+b2a7152"}

        iex> Mix.Tasks.YmerNode.Deploy.serverinfo_version("not json")
        :error

    """
    def serverinfo_version(body) when is_binary(body) do
      with {:ok, decoded} <- JSON.decode(body),
           %{"result" => %{"_meta" => %{@serverinfo_field => %{"version" => version}}}} <-
             decoded do
        {:ok, version}
      else
        _unreadable -> :error
      end
    end

    @doc """
    The request the deploy's last check sends, as the headers and body `curl`
    posts: a `server/discover`, which touches no tool and no store. The
    protocol fields ride in `params._meta`, and the two headers that mirror
    the body — `MCP-Protocol-Version` and `Mcp-Method` — go with it, because
    the node refuses a request whose mirrored headers are missing or disagree
    with the body. Public so a test can send these exact bytes through the
    node's mount.

    ## Examples

        iex> {headers, body} = Mix.Tasks.YmerNode.Deploy.discover_request()
        iex> headers
        [
          {"content-type", "application/json"},
          {"accept", "application/json, text/event-stream"},
          {"mcp-protocol-version", "2026-07-28"},
          {"mcp-method", "server/discover"}
        ]
        iex> JSON.decode!(body)
        %{
          "id" => 1,
          "jsonrpc" => "2.0",
          "method" => "server/discover",
          "params" => %{
            "_meta" => %{
              "io.modelcontextprotocol/clientCapabilities" => %{},
              "io.modelcontextprotocol/protocolVersion" => "2026-07-28"
            }
          }
        }

    """
    def discover_request do
      body =
        JSON.encode!(%{
          "jsonrpc" => "2.0",
          "id" => 1,
          "method" => "server/discover",
          "params" => %{
            "_meta" => %{
              "io.modelcontextprotocol/protocolVersion" => @protocol_version,
              "io.modelcontextprotocol/clientCapabilities" => %{}
            }
          }
        })

      headers = [
        {"content-type", "application/json"},
        {"accept", "application/json, text/event-stream"},
        {"mcp-protocol-version", @protocol_version},
        {"mcp-method", "server/discover"}
      ]

      {headers, body}
    end

    @doc """
    Whether the container is running the image just built. Compares image
    **ids**: the reference a container was created from reads the same whether
    or not the recreate took, because the tag string does not move with the
    image it names. An id that could not be read refuses too: the proof this
    check carries cannot rest on two failed reads comparing equal.

    ## Examples

        iex> Mix.Tasks.YmerNode.Deploy.image_refusal({:ok, "sha256:abc"}, {:ok, "sha256:abc"})
        :ok

        iex> {:refuse, message} = Mix.Tasks.YmerNode.Deploy.image_refusal({:ok, "sha256:a"}, {:ok, "sha256:b"})
        iex> String.contains?(message, "did not take")
        true

        iex> {:refuse, message} = Mix.Tasks.YmerNode.Deploy.image_refusal({:error, "the install's container"}, {:ok, "sha256:b"})
        iex> String.contains?(message, "could not inspect the install's container")
        true

    """
    def image_refusal({:ok, image_id}, {:ok, image_id}) when is_binary(image_id), do: :ok

    def image_refusal({:ok, running_id}, {:ok, expected_id})
        when is_binary(running_id) and is_binary(expected_id) do
      {:refuse,
       "The install's container runs image #{running_id}, but the build produced " <>
         "#{expected_id}. The recreate did not take — read the compose output above."}
    end

    def image_refusal({:error, what}, _expected) when is_binary(what), do: unreadable_image(what)
    def image_refusal(_running, {:error, what}) when is_binary(what), do: unreadable_image(what)

    defp unreadable_image(what) do
      {:refuse,
       "Docker could not inspect #{what}, so nothing proves the install runs the " <>
         "image just built. Read `docker inspect` on it, then rerun mix ymer_node.deploy."}
    end

    @impl Mix.Task
    def run([]) do
      root = Build.preflight!()
      spelling = detect_compose_spelling()
      install = install_dir()

      refuse!(tree_refusal(read_tree_state(root)))
      refuse!(branch_refusal(current_branch(root)))
      refuse!(install_path_refusal(real_path(install), root))
      refuse!(compose_file_refusal(install, File.regular?(compose_path(install))))
      refuse!(compose_shadow_refusal(install, shadowing_compose_files(install)))
      refuse!(running_refusal(install, spelling, read_running_state(spelling, install)))

      rollback = name_rollback_target(spelling, install)

      built = Build.build!()
      compose_state = carry_compose!(root, install)
      compose_up!(spelling, install)

      {port, wire} = verify!(spelling, install, built)
      announce(built, compose_state, rollback, install, port, wire)
    end

    def run(argv) do
      Mix.raise("mix ymer_node.deploy takes no arguments (got: #{Enum.join(argv, " ")})")
    end

    defp refuse!(:ok), do: :ok
    defp refuse!({:refuse, message}), do: Mix.raise(message)

    defp port_in_line(line) do
      case Regex.run(~r/:(\d+)\s*$/, line) do
        [_match, port] -> {:ok, String.to_integer(port)}
        nil -> nil
      end
    end

    defp install_dir do
      @install_dir_env
      |> System.get_env()
      |> install_dir_setting()
      |> Path.expand()
    end

    defp compose_path(dir), do: Path.join(dir, @compose_file)

    defp shadowing_compose_files(install) do
      Enum.filter(@shadowing_compose_files, &File.regular?(Path.join(install, &1)))
    end

    # `Path.expand/1` resolves `.`, `..` and `~` and stops there, while the
    # checkout root arrives from `File.cwd!/0` already symlink-resolved — so a
    # string compare would read an install reached through a link into the
    # checkout as unrelated to it. A directory that does not exist is left as
    # configured, so a misspelled path still reaches the compose-file refusal
    # and its message rather than raising here. `File.cd!/2` restores the
    # working directory before returning.
    defp real_path(dir) do
      if File.dir?(dir), do: File.cd!(dir, fn -> File.cwd!() end), else: dir
    end

    # The classifier reads an atom, so what is dirty is printed here, from the
    # same `git status` that classified it — the split `read_running_state/2`
    # keeps between a compose failure and the one-line refusal under it. The
    # listing matters because `--porcelain` counts untracked files as dirt,
    # and neither commit nor stash clears those.
    defp read_tree_state(root) do
      {state, listing} = Build.tree_status(root)
      report_captured(listing)
      state
    end

    # stdout only, as `Build.git_short_sha/1` reads: this output is compared
    # against `main`, and a merged notice on stderr would refuse a deploy from
    # the right branch with a message naming the notice as the branch.
    defp current_branch(root) do
      args = ["rev-parse", "--abbrev-ref", "HEAD"]

      case System.cmd("git", args, cd: root) do
        {output, 0} -> String.trim(output)
        {_output, _status} -> "an unreadable branch"
      end
    end

    defp detect_compose_spelling do
      compose_spelling(
        Build.docker_answers?(["compose", "version"]),
        System.find_executable("docker-compose") != nil
      )
    end

    # stderr is deliberately NOT merged here, nor in the two readers below.
    # `ps -q` prints container ids on stdout and warnings on stderr, and this
    # output is classified as ids: merged, an exit-0 warning — two compose
    # files in the install, an orphan container, a deprecated key — is
    # non-empty output and reads as `:running`, refusing the deploy with a
    # message no amount of stopping can clear. Unmerged, compose's own stderr
    # still reaches the operator's terminal directly, which is what the
    # refusal wants in front of them.
    defp read_running_state(spelling, install) do
      {executable, args} = compose_argv(spelling, ["ps", "-q"])
      {output, status} = System.cmd(executable, args, cd: install)

      case compose_running_state(output, status) do
        :unknown ->
          report_captured(output)
          :unknown

        state ->
          state
      end
    end

    # Captured output goes under whatever is about to be refused — a compose
    # failure's stdout, the dirty tree's listing. Empty prints nothing: a blank
    # line under a refusal would read as its explanation. Compose's own stderr
    # is not captured (see `read_running_state/2`) and reaches the terminal
    # directly, ahead of the refusal.
    defp report_captured(output) do
      case String.trim(output) do
        "" -> :ok
        trimmed -> Mix.shell().info([:yellow, trimmed, :reset])
      end
    end

    # The verify below reads the same command, and its empty case already fails
    # closed: after `up -d` there must be a container, so nothing found is a
    # raise either way and the exit status adds nothing to it.
    defp compose_ps(spelling, install) do
      {executable, args} = compose_argv(spelling, ["ps", "-q"])

      case System.cmd(executable, args, cd: install) do
        {output, 0} -> output
        {_output, _status} -> ""
      end
    end

    defp name_rollback_target(spelling, install) do
      container = install_container(spelling, install)
      revision = container_revision(container)

      case rollback_target(container, revision, revision_tag_present?(revision)) do
        {:tag, target} -> point_previous_at(target)
        {:skip, reason} -> {:skip, reason}
      end
    end

    defp install_container(spelling, install) do
      {executable, args} = compose_argv(spelling, ["ps", "-a", "-q"])

      case System.cmd(executable, args, cd: install) do
        {output, 0} -> first_container_id(output)
        {_output, _status} -> :unreadable
      end
    end

    defp first_container_id(output) do
      output
      |> String.split("\n", trim: true)
      |> List.first("")
      |> String.trim()
    end

    defp container_revision(:unreadable), do: ""
    defp container_revision(""), do: ""

    defp container_revision(container) do
      format = "{{index .Config.Labels \"#{Build.revision_label()}\"}}"
      args = ["inspect", container, "--format", format]

      # stdout only: this output is the revision `previous` is pointed at, and
      # a merged warning would be looked up as a tag and reported as missing.
      case System.cmd("docker", args) do
        {output, 0} -> String.trim(output)
        {_output, _status} -> ""
      end
    end

    defp revision_tag_present?(""), do: false

    defp revision_tag_present?(revision) do
      Build.docker_answers?(["image", "inspect", "#{@image}:#{revision}"])
    end

    defp point_previous_at(revision) do
      previous = "#{@image}:#{@previous_tag}"
      target = "#{@image}:#{revision}"

      case System.cmd("docker", ["tag", target, previous], stderr_to_stdout: true) do
        {_output, 0} -> {:named, revision}
        {_output, _status} -> {:skip, "docker could not point #{previous} at #{target}"}
      end
    end

    defp carry_compose!(root, install) do
      source = compose_path(root)
      target = compose_path(install)

      if File.read!(source) == File.read!(target) do
        :unchanged
      else
        File.cp!(source, target)
        :updated
      end
    end

    defp compose_up!(spelling, install) do
      {executable, args} = compose_argv(spelling, ["up", "-d"])
      Mix.shell().info([:cyan, "\n==> #{spelling} up -d in #{install}", :reset])

      {_output, status} =
        System.cmd(executable, args,
          cd: install,
          stderr_to_stdout: true,
          into: Build.live_output(:stdio)
        )

      if status != 0 do
        Mix.raise("#{spelling} up -d failed in #{install} (exit status #{status}).")
      end
    end

    defp verify!(spelling, install, built) do
      container = String.trim(compose_ps(spelling, install))

      if container == "" do
        Mix.raise("""
        Compose reported no container in #{install} after `up -d`.
        Read `#{spelling} ps -a` there — the container was created and is already gone.
        """)
      end

      refuse!(image_refusal(container_image(container), built_image_id()))

      port = published_port!(container, install, spelling)
      wire = wire_version(built.version, built.revision)

      context = %{
        port: port,
        wire: wire,
        container: container,
        spelling: spelling,
        install: install
      }

      poll!(context, System.monotonic_time(:millisecond) + @readiness_budget_ms)

      {port, wire}
    end

    defp poll!(context, deadline) do
      answer = answered_version(context.port)

      cond do
        answer == {:ok, context.wire} ->
          :ok

        System.monotonic_time(:millisecond) >= deadline ->
          never_answered!(context, answer)

        true ->
          fail_fast_on_dead_container!(context, answer)
          Process.sleep(@readiness_interval_ms)
          poll!(context, deadline)
      end
    end

    defp never_answered!(context, answer) do
      {state, restarts} = container_state(context.container)

      Mix.raise("""
      The node never answered #{context.wire} on 127.0.0.1:#{context.port} (last: #{describe_answer(answer)}).
      Its container is '#{state}', restart count #{restarts}.
      Read `#{context.spelling} logs` in #{context.install}.
      """)
    end

    defp fail_fast_on_dead_container!(context, answer) do
      {state, restarts} = container_state(context.container)

      if state in @dead_container_states do
        Mix.raise("""
        The install's container is '#{state}' (restart count #{restarts}) and the
        node answers #{describe_answer(answer)} — it is not staying up.
        Read `#{context.spelling} logs` in #{context.install}.
        """)
      end

      :ok
    end

    defp describe_answer({:ok, version}), do: "version #{version}"
    defp describe_answer(:error), do: "nothing readable"

    defp answered_version(port) do
      {headers, body} = discover_request()
      header_args = Enum.flat_map(headers, fn {name, value} -> ["-H", "#{name}: #{value}"] end)

      args =
        ["-s", "-X", "POST"] ++
          header_args ++ ["--max-time", "5", "-d", body, "http://127.0.0.1:#{port}/mcp"]

      # stdout only: the body is decoded as JSON, and a merged curl notice
      # ahead of it would make every probe unreadable on a node that answers.
      case System.cmd("curl", args) do
        {output, 0} -> serverinfo_version(output)
        {_output, _status} -> :error
      end
    end

    # stdout only, both readers: the ids are compared for identity, and a read
    # that fails says so instead of standing in a sentinel — a sentinel lives
    # in the same value space as an id, and two equal ones would pass the
    # identity check on no evidence.
    defp built_image_id do
      args = ["image", "inspect", "#{@image}:latest", "--format", "{{.Id}}"]

      case System.cmd("docker", args) do
        {output, 0} -> {:ok, String.trim(output)}
        {_output, _status} -> {:error, "#{@image}:latest"}
      end
    end

    defp container_image(container) do
      args = ["inspect", container, "--format", "{{.Image}}"]

      case System.cmd("docker", args) do
        {output, 0} -> {:ok, String.trim(output)}
        {_output, _status} -> {:error, "the install's container"}
      end
    end

    # stdout only: the first word of this output is the container's state, and
    # a merged warning's first word would stand in for it — never a dead state,
    # so the fail-fast above would never fire.
    defp container_state(container) do
      args = ["inspect", container, "--format", "{{.State.Status}} {{.RestartCount}}"]

      case System.cmd("docker", args) do
        {output, 0} -> parse_state(output)
        {_output, _status} -> {"unknown", "?"}
      end
    end

    defp parse_state(output) do
      case output |> String.trim() |> String.split(" ", parts: 2) do
        [state, restarts] -> {state, restarts}
        _unreadable -> {"unknown", "?"}
      end
    end

    # stdout only: the port is parsed out of this output, and a merged warning
    # ending in a number would be dialled as the port.
    defp published_port!(container, install, spelling) do
      {output, _status} = System.cmd("docker", ["port", container])

      case published_port(output) do
        {:ok, port} ->
          port

        :error ->
          Mix.raise("""
          Docker reports no published port for the install's container.
          Read `#{spelling} ps -a` in #{install} — a container that is not
          running publishes nothing.
          """)
      end
    end

    defp announce(built, compose_state, rollback, install, port, wire) do
      Mix.shell().info([:green, "\n✓ Deployed #{Enum.join(built.tags, " + ")}", :reset])
      Mix.shell().info("  Compose file #{compose_state} in #{install}.")
      Mix.shell().info("  " <> rollback_line(rollback))
      Mix.shell().info("  The node answers #{wire} at http://127.0.0.1:#{port}/mcp.")
      Mix.shell().info("  Connected clients keep working; reconnect one to see changed tools.")
    end
  end
end
