defmodule Mix.Tasks.YmerNode.BrowserCheckTest do
  @moduledoc """
  Covers the task's two refusals and its decision to install first, the last
  over directories of the test's own with their times set by hand. What the
  task proves, it proves by running: `node --test` against a real browser,
  which the node's suite does not start.

  Not async: the missing-Node.js case empties `PATH` for its duration, and
  `PATH` is the VM's.
  """
  use ExUnit.Case, async: false

  alias Mix.Tasks.YmerNode.BrowserCheck

  describe "run/1" do
    test "refuses arguments instead of ignoring them" do
      assert_raise Mix.Error, ~r/takes no arguments/, fn ->
        BrowserCheck.run(["--fast"])
      end
    end

    test "names Node.js when npm is not on the PATH" do
      saved = System.get_env("PATH")
      on_exit(fn -> System.put_env("PATH", saved) end)
      System.put_env("PATH", "")

      assert_raise Mix.Error, ~r/needs Node\.js 20 or later/, fn ->
        BrowserCheck.run([])
      end
    end
  end

  describe "stale?/1" do
    @describetag :tmp_dir

    test "is stale when nothing is installed", %{tmp_dir: directory} do
      File.write!(Path.join(directory, "package-lock.json"), "{}")

      assert BrowserCheck.stale?(directory)
    end

    test "is stale when the lockfile is newer than the installed tree", %{tmp_dir: directory} do
      installed = install(directory)
      File.touch!(installed, 1_000)
      File.touch!(Path.join(directory, "package-lock.json"), 2_000)

      assert BrowserCheck.stale?(directory)
    end

    test "is current when the installed tree is as new as the lockfile", %{tmp_dir: directory} do
      installed = install(directory)
      File.touch!(Path.join(directory, "package-lock.json"), 2_000)
      File.touch!(installed, 2_000)

      refute BrowserCheck.stale?(directory)
    end
  end

  defp install(directory) do
    File.write!(Path.join(directory, "package-lock.json"), "{}")
    installed = Path.join([directory, "node_modules", ".package-lock.json"])
    File.mkdir_p!(Path.dirname(installed))
    File.write!(installed, "{}")
    installed
  end
end
