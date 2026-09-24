defmodule YmerNode.SecretsTest do
  @moduledoc """
  Every case points `YmerNode.Secrets` at a file of its own under `tmp_dir` and
  restores the application env on exit, so the checkout's real dev secrets file
  is never read or written.

  **Not async, and the tmp_dir is not why.** Each case owns its file, but the
  *pointer* to it — `config :ymer_node, YmerNode.Secrets, :path` — is VM-global
  application config, and `YmerNode.ScriptContextTest`,
  `YmerNode.ScriptHarnessTest` and `YmerNode.ScriptTestSupportTest` set the same
  key. Two async modules would then race: one module's `set/2` would
  read the other's path, and a case that deliberately chmods its file `0644` to
  prove the permissive refusal would hand that refusal to whichever case was
  mid-write. Observed exactly that way at authoring — `set/2` answered
  `{:error, {:secrets_file_permissive, "644"}}` in a case whose own file was
  `0600`. A tmp_dir isolates the file; nothing isolates the config key.

  `@tag :tmp_dir` is what creates that directory; a case without it has no
  `tmp_dir` in its context and will fail on the setup's `Path.join/2`.
  """
  use ExUnit.Case, async: false

  alias YmerNode.Secrets

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    saved = Application.get_env(:ymer_node, Secrets)
    path = Path.join(tmp_dir, "secrets.env")
    Application.put_env(:ymer_node, Secrets, path: path)

    on_exit(fn ->
      if saved, do: Application.put_env(:ymer_node, Secrets, saved)
    end)

    %{path: path}
  end

  defp write!(path, contents) do
    File.write!(path, contents)
    File.chmod!(path, 0o600)
  end

  describe "path/0" do
    @tag doc: """
         A VM running script code outside the node has none of the node's
         environments to set the key, so this refusal is where its author
         learns which call points it. A failure means the lookup started
         inventing a path — a VM missing the key would then write secrets
         somewhere nobody arranged — or the message stopped naming the setter.
         """
    test "refuses an unset path by name, naming the harness setter" do
      Application.delete_env(:ymer_node, Secrets)

      error = assert_raise ArgumentError, fn -> Secrets.path() end

      assert error.message =~ "path:"
      assert error.message =~ "SECRETS_PATH"
      assert error.message =~ "YmerNode.Script.Harness.put_secrets_path/1"
    end
  end

  describe "get/1" do
    test "answers the value a line sets", %{path: path} do
      write!(path, "JIRA_TOKEN=abc123\n")

      assert Secrets.get("JIRA_TOKEN") == {:ok, "abc123"}
    end

    test "skips blank lines, comments and lines with no equals", %{path: path} do
      write!(path, "\n# a comment\nnot a setting\n\nA=1\n")

      assert Secrets.get("A") == {:ok, "1"}
      assert Secrets.get("# a comment") == {:error, :secret_not_found}
    end

    test "splits on the FIRST equals, so a value may carry one", %{path: path} do
      write!(path, "DSN=postgres://u:p@h/db?a=b\n")

      assert Secrets.get("DSN") == {:ok, "postgres://u:p@h/db?a=b"}
    end

    test "unwraps a wholly quoted value once, and only then", %{path: path} do
      write!(path, ~s|A="a b"\nB='c d'\nC=say "hi"\nD="unbalanced\n|)

      assert Secrets.get("A") == {:ok, "a b"}
      assert Secrets.get("B") == {:ok, "c d"}
      assert Secrets.get("C") == {:ok, ~s|say "hi"|}
      assert Secrets.get("D") == {:ok, ~s|"unbalanced|}
    end

    test "a later duplicate wins, which is what an appended hand-edit expects", %{path: path} do
      write!(path, "A=first\nA=second\n")

      assert Secrets.get("A") == {:ok, "second"}
    end

    test "answers :secret_not_found for a name the file does not set", %{path: path} do
      write!(path, "A=1\n")

      assert Secrets.get("B") == {:error, :secret_not_found}
    end

    test "answers :secrets_file_missing when there is no file at all" do
      assert Secrets.get("A") == {:error, :secrets_file_missing}
    end

    @tag doc: """
         Guards the mode check, which is the module's only security claim: a
         secret in a file any other account can read is not a secret. A failure
         means the check went one-sided (owner bits only) or was dropped — the
         node would then serve values out of a world-readable file without
         saying so. `0o077` is the mask, so `0600` and `0400` both pass and
         `0640` does not.
         """
    test "refuses a file any group or other bit can read", %{path: path} do
      write!(path, "A=1\n")
      File.chmod!(path, 0o644)

      assert Secrets.get("A") == {:error, {:secrets_file_permissive, "644"}}
      assert Secrets.list() == {:error, {:secrets_file_permissive, "644"}}

      File.chmod!(path, 0o400)
      assert Secrets.get("A") == {:ok, "1"}
    end
  end

  describe "list/0" do
    test "answers names, sorted, and never a value", %{path: path} do
      write!(path, "ZED=z\nALPHA=a\n# NOPE=x\n")

      assert Secrets.list() == {:ok, ["ALPHA", "ZED"]}
    end

    test "answers an empty list for a file of comments", %{path: path} do
      write!(path, "# nothing here\n")

      assert Secrets.list() == {:ok, []}
    end
  end

  describe "set/2" do
    test "creates the file 0600 on the first set", %{path: path, tmp_dir: tmp_dir} do
      refute File.exists?(path)

      assert Secrets.set("A", "1") == :ok
      assert Secrets.get("A") == {:ok, "1"}
      assert %File.Stat{mode: mode} = File.stat!(path)
      assert Bitwise.band(mode, 0o777) == 0o600

      # The contents go to a neighbouring temp file and are renamed over the
      # target, so the secret can never be lost half-written. `File.ls!/1` lists
      # hidden entries too, which is what makes this the temp file's gate: the
      # directory holds the secrets file and nothing else once the set lands.
      assert File.ls!(tmp_dir) == ["secrets.env"]
    end

    @tag doc: """
         Guards the in-place replace. A set that appended instead would leave
         the old line above the new one — harmless while a later duplicate wins,
         but it grows the file without bound and puts a superseded secret on
         disk forever. A failure means `replace_or_append/3` stopped matching,
         which is also what would break a hand-written comment's position.
         """
    test "replaces a name in place, keeping comments and order", %{path: path} do
      write!(path, "# routing\nA=old\nB=2\n")

      assert Secrets.set("A", "new") == :ok
      assert File.read!(path) == "# routing\nA=new\nB=2\n"
    end

    @tag doc: """
         An operator's blank line between two groups is part of the file the
         way a comment is. A rewrite that dropped every empty element — the
         easy way to lose the split's trailing terminator — flattened a
         hand-kept layout on the first set. A failure here means the terminator
         and an interior blank are no longer being told apart.
         """
    test "keeps a blank line between groups across a set and an unset", %{path: path} do
      write!(path, "# aws\nA=1\n\n# jira\nB=2\n")

      assert Secrets.set("B", "3") == :ok
      assert File.read!(path) == "# aws\nA=1\n\n# jira\nB=3\n"

      assert Secrets.unset("A") == :ok
      assert File.read!(path) == "# aws\n\n# jira\nB=3\n"
    end

    test "appends a name the file does not carry", %{path: path} do
      write!(path, "A=1\n")

      assert Secrets.set("B", "2") == :ok
      assert File.read!(path) == "A=1\nB=2\n"
    end

    test "chmods an existing file back to 0600", %{path: path} do
      write!(path, "A=1\n")
      File.chmod!(path, 0o600)

      assert Secrets.set("B", "2") == :ok
      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    end

    test "refuses a name that is not an environment-variable name" do
      assert Secrets.set("has space", "1") == {:error, :invalid_secret_name}
      assert Secrets.set("1LEADING", "1") == {:error, :invalid_secret_name}
      assert Secrets.set("", "1") == {:error, :invalid_secret_name}
    end

    test "refuses a value carrying a newline" do
      assert Secrets.set("A", "one\ntwo") == {:error, :invalid_secret_value}
    end
  end

  describe "unset/1" do
    test "removes the line and answers :ok", %{path: path} do
      write!(path, "A=1\nB=2\n")

      assert Secrets.unset("A") == :ok
      assert File.read!(path) == "B=2\n"
      assert Secrets.get("A") == {:error, :secret_not_found}
    end

    test "answers :secret_not_found rather than reporting a no-op as success", %{path: path} do
      write!(path, "A=1\n")

      assert Secrets.unset("B") == {:error, :secret_not_found}
      assert File.read!(path) == "A=1\n"
    end

    test "answers :secret_not_found when there is no file" do
      assert Secrets.unset("A") == {:error, :secret_not_found}
    end
  end
end
