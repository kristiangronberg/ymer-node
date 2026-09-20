defmodule Mix.Tasks.YmerNode.DeployTest do
  @moduledoc """
  Covers the task's pure decisions and its refusal of arguments. Nothing here
  shells out, so the file needs no Docker daemon, no `git`, no install and no
  network — the behaviour that does shell out is proved by running the task
  itself against a real install.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.YmerNode.Deploy

  doctest Deploy

  describe "run/1" do
    @tag doc: """
         Pins the option-less contract: a flag arrives as an argument list,
         and the task has to say it takes none rather than quietly deploying
         something the caller did not ask for. A failure means an
         argument-accepting clause was added or the clauses were reordered —
         restore the refusal rather than relaxing the assertion.
         """
    test "refuses arguments instead of ignoring them" do
      assert_raise Mix.Error, ~r/takes no arguments/, fn ->
        Deploy.run(["--rollback"])
      end
    end
  end

  describe "compose_argv/2" do
    test "extra spacing in a spelling does not become an empty argument" do
      assert Deploy.compose_argv("docker  compose", ["ps"]) == {"docker", ["compose", "ps"]}
    end
  end

  describe "install_path_refusal/2" do
    @tag doc: """
         Guards the prefix check against the sibling-directory false
         positive: `/src/ymer-node-install` starts with `/src/ymer-node` as a
         string but is not inside it. A failure means the separator was
         dropped from the comparison, and every deploy to a sibling of the
         checkout would refuse.
         """
    test "a sibling whose name extends the checkout's is not inside it" do
      refusal = Deploy.install_path_refusal("/src/ymer-node-install", "/src/ymer-node")

      assert refusal == :ok
    end
  end

  describe "compose_running_state/2" do
    test "whitespace-only output on a clean exit reads as not running" do
      assert Deploy.compose_running_state("  \n  ", 0) == :not_running
    end

    @tag doc: """
         The gate this feeds exists to keep a deploy off a live container, so
         a compose invocation that failed must not read like compose answering
         that nothing is up. A failure here means the exit status stopped
         being part of the reading, and a deploy would recreate a running node
         whenever `ps -q` errored.
         """
    test "a non-zero exit is unknown whatever the command printed" do
      assert Deploy.compose_running_state("", 1) == :unknown
      assert Deploy.compose_running_state("abc123\n", 1) == :unknown
    end
  end

  describe "running_refusal/3" do
    test "the refusal names the install directory and nothing else to do" do
      {:refuse, message} = Deploy.running_refusal("/opt/node", "dc", :running)

      assert message =~ "/opt/node"
      assert message =~ "`dc stop`"
    end

    test "an unreadable state refuses instead of reading as not running" do
      assert {:refuse, message} = Deploy.running_refusal("/opt/node", "dc", :unknown)

      assert message =~ "/opt/node"
      assert message =~ "`dc ps -q`"
    end
  end

  describe "rollback_target/3" do
    @tag doc: """
         The only path that names a target. A failure means either the guard
         on the tag reading was dropped — `previous` would be pointed at a
         tag Docker cannot resolve, and the deploy would report a rollback
         target that does not exist — or the returned tuple's shape changed
         out from under the caller that runs `docker tag`.
         """
    test "all three readings present is the one case that names a target" do
      assert Deploy.rollback_target("abc123", "b2a7152", true) == {:tag, "b2a7152"}
    end

    test "a dirty revision names a target like any other" do
      assert Deploy.rollback_target("abc123", "b2a7152-dirty", true) == {:tag, "b2a7152-dirty"}
    end

    @tag doc: """
         The three readings are taken in order and only the last one names a
         target, so this pins that every earlier absence wins over a later
         reading. A container that is missing must not be rescued by a stale
         revision string, and a revision with no tag must not be pointed at.
         A failure means the clauses were reordered, and a deploy would tag
         `previous` onto something that is not there.
         """
    test "an absent container wins over anything read after it" do
      assert {:skip, reason} = Deploy.rollback_target("", "b2a7152", true)

      assert reason =~ "no container"
    end

    test "a container with no label wins over a tag that happens to resolve" do
      assert {:skip, reason} = Deploy.rollback_target("abc123", "", true)

      assert reason =~ "no revision label"
    end

    test "a container reading compose could not make names nothing" do
      assert {:skip, reason} = Deploy.rollback_target(:unreadable, "b2a7152", true)

      assert reason =~ "could not read"
    end

    test "the missing-tag reason names the tag it looked for" do
      assert {:skip, reason} = Deploy.rollback_target("abc123", "b2a7152", false)

      assert reason =~ "ymer-node:b2a7152"
    end
  end

  describe "rollback_line/1" do
    @tag doc: """
         The close's only statement about the rollback target, so a reader
         must be able to tell "named" from "not named" without knowing the
         internals. A failure means the two outcomes have started reading
         alike.
         """
    test "a named target and a skipped one do not read alike" do
      named = Deploy.rollback_line({:named, "b2a7152"})
      skipped = Deploy.rollback_line({:skip, "the install had no container"})

      assert named =~ "ymer-node:previous"
      assert named =~ "ymer-node:b2a7152"
      assert skipped =~ "none"
      refute skipped =~ "ymer-node:previous"
    end
  end

  describe "published_port/1" do
    test "a trailing newline does not hide the port" do
      assert Deploy.published_port("8012/tcp -> 127.0.0.1:8012\n") == {:ok, 8012}
    end

    @tag doc: """
         Docker prints one line per published port. A failure means the
         parser stopped taking the first readable line, which would make the
         verify probe a port the node is not answering on.
         """
    test "the first published port wins when several are listed" do
      output = "8012/tcp -> 127.0.0.1:8012\n9000/tcp -> 127.0.0.1:9000\n"

      assert Deploy.published_port(output) == {:ok, 8012}
    end
  end

  describe "serverinfo_version/1" do
    test "valid JSON without a serverInfo version is an error, not a crash" do
      assert Deploy.serverinfo_version(~s({"result":{}})) == :error
    end

    test "a JSON-RPC error response is an error" do
      assert Deploy.serverinfo_version(~s({"error":{"code":-32600}})) == :error
    end
  end

  describe "wire_version/2" do
    test "the separator is the semver build-metadata plus" do
      assert Deploy.wire_version("1.2.3", "b2a7152") == "1.2.3+b2a7152"
    end
  end
end
