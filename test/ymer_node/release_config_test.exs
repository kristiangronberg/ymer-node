defmodule YmerNode.ReleaseConfigTest do
  @moduledoc """
  Evaluates the real `config/runtime.exs` as `:prod` through `Config.Reader`, the
  one way a suite case can see what a release boot does: `mix test` runs that file
  at `:test`, where the whole prod block is dead, so an unconditional wide bind
  written there keeps every other case green while every bare release binds all
  interfaces. Not `async`: the file reads the VM's environment, so this module
  clears the integer variables it reads through `integer_env`, and `TZ`, for the
  duration and restores them on exit, and points the databases directory and
  the files directory at a tmp dir because the file's own `File.mkdir_p!` runs
  on both before any read — `/data` is not creatable on a developer's machine.

  The marker path, the variable names and the files directory's default are
  read off the file under test at compile time rather than spelled here: the
  Dockerfile and `config/runtime.exs` stay the *bind marker*'s only two
  spellings (`docs/glossary.md` defines the term), and a rename there is
  followed here. The guard case is skipped, its
  reason in the run's summary, on a machine that carries the marker — the case
  cannot discriminate there.
  """
  use ExUnit.Case, async: false

  @runtime_config Path.expand("../../config/runtime.exs", __DIR__)
  @databases_variable "DATABASES_PATH"
  @files_variable "FILES_PATH"
  # Named here so `setup` can save and restore it: the retired-variable case
  # below sets it, and this module's contract is that it puts back every
  # variable it touches.
  @retired_variable "NOTEBOOK_DATABASE_PATH"

  # Named here too, and cleared before every case: the file reads it, so a TZ
  # the shell running the suite exports would reach every case's read — and one
  # the release's zone database does not know would make each of them raise.
  @time_zone_variable "TZ"

  runtime_source = File.read!(@runtime_config)
  [_, marker] = Regex.run(~r/File\.exists\?\("([^"]+)"\)/, runtime_source)
  @marker marker

  # The default is read off the source because the read that would show it —
  # the variable unset — creates the directory under /data, which this machine
  # refuses; the release probe and the install are where it is seen created.
  [_, files_default] = Regex.run(~r/env\.\("FILES_PATH"\) \|\| "([^"]+)"/, runtime_source)
  @files_default files_default

  @integer_variables ~r/integer_env\.\("([A-Z_]+)"/
                     |> Regex.scan(runtime_source)
                     |> Enum.map(fn [_, name] -> name end)
                     |> Enum.uniq()

  setup do
    saved =
      Map.new(
        [
          @databases_variable,
          @files_variable,
          @retired_variable,
          @time_zone_variable | @integer_variables
        ],
        &{&1, System.get_env(&1)}
      )

    tmp =
      Path.join(
        System.tmp_dir!(),
        "ymer-node-release-config-#{System.unique_integer([:positive])}"
      )

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      File.rm_rf!(tmp)
    end)

    Enum.each(@integer_variables, &System.delete_env/1)
    System.delete_env(@time_zone_variable)
    System.put_env(@databases_variable, Path.join(tmp, "db"))
    System.put_env(@files_variable, Path.join(tmp, "files"))
    %{files_dir: Path.join(tmp, "files")}
  end

  defp release_mcp_config do
    @runtime_config
    |> Config.Reader.read!(env: :prod)
    |> get_in([:ymer_node, YmerNode.Mcp])
  end

  defp release_time_zone do
    @runtime_config
    |> Config.Reader.read!(env: :prod)
    |> get_in([:ymer_node, YmerNode.Script.Context, :time_zone])
  end

  defp release_files_dir do
    @runtime_config
    |> Config.Reader.read!(env: :prod)
    |> get_in([:ymer_node, YmerNode.Script.Context, :files_dir])
  end

  describe "the bind marker" do
    @tag doc: """
         Pins the other condition a bare `bin/ymer_node start` needs to bind
         loopback — `YmerNode.McpTest` pins that `config/prod.exs` sets no bind
         address; this case pins that `config/runtime.exs` widens only behind the
         bind marker, by evaluating the guard itself on a machine that has no
         marker. A failure means the widening lost its guard — a dropped `if`, an
         inverted one, or a `config` call that slipped outside it — and a bare
         release now exposes an unauthenticated SQL surface to its host's networks.
         On a machine carrying the marker the case is skipped, never failed: it
         cannot tell a correct widening from a lost guard there.
         """
    @tag skip:
           File.exists?(@marker) &&
             "this machine carries the bind marker, so the guard case cannot discriminate here"
    test "the release boot config widens the bind only behind the marker" do
      refute Keyword.has_key?(release_mcp_config() || [], :ip)
    end

    @tag doc: """
         The positive control for the case above: the same read, with `PORT` set,
         must land a value under `YmerNode.Mcp`. Without it a `nil` from the guard
         case could be a read that reached the wrong key and found nothing, which
         proves nothing about the guard.
         """
    test "the same read sees a PORT the environment sets" do
      System.put_env("PORT", "9001")

      assert Keyword.fetch!(release_mcp_config(), :port) == 9001
    end

    @tag doc: """
         The control for the compile-time reads above: the marker path and the
         integer variable names come off `config/runtime.exs` itself. A failure
         means the file's shape moved — the `File.exists?` guard or the
         `integer_env` calls are spelled differently — and the two cases above are
         clearing the wrong variables or watching the wrong path.
         """
    test "the module reads its constants off the file under test" do
      assert String.starts_with?(@marker, "/")
      assert String.starts_with?(@files_default, "/")
      assert "PORT" in @integer_variables
    end
  end

  describe "the databases directory" do
    @tag doc: """
         Pins the one-directory rule: the operator names a directory and the node
         places both database files inside it under fixed names. A failure means a
         repo's path stopped deriving from `DATABASES_PATH` — a per-file variable
         come back, or a path hardcoded past the read — and an install repointed
         at a new directory would leave one of its databases behind in the old one.
         """
    test "both repos derive their database file from DATABASES_PATH" do
      dir =
        Path.join(
          System.tmp_dir!(),
          "ymer-node-databases-#{System.unique_integer([:positive])}"
        )

      System.put_env(@databases_variable, dir)

      on_exit(fn ->
        System.delete_env(@databases_variable)
        File.rm_rf!(dir)
      end)

      repos =
        @runtime_config
        |> Config.Reader.read!(env: :prod)
        |> Keyword.fetch!(:ymer_node)

      assert Keyword.fetch!(repos, YmerNode.Notebook.Repo)[:database] ==
               Path.join(dir, "notebook.db")

      assert Keyword.fetch!(repos, YmerNode.Repo)[:database] == Path.join(dir, "node.db")
    end

    @tag doc: """
         The retired variable. `NOTEBOOK_DATABASE_PATH` named a file and a
         directory variable replaced it; an install that still exports the old
         name must not go on placing the store by it, because the node database
         would then be written somewhere else entirely. A failure means the old
         read came back and two variables now compete for where the store lives.
         """
    test "the retired per-file variable no longer places the store" do
      dir =
        Path.join(
          System.tmp_dir!(),
          "ymer-node-databases-#{System.unique_integer([:positive])}"
        )

      System.put_env(@databases_variable, dir)
      System.put_env(@retired_variable, Path.join(dir, "ignored/notebook.db"))

      on_exit(fn ->
        System.delete_env(@databases_variable)
        System.delete_env(@retired_variable)
        File.rm_rf!(dir)
      end)

      database =
        @runtime_config
        |> Config.Reader.read!(env: :prod)
        |> get_in([:ymer_node, YmerNode.Notebook.Repo, :database])

      assert database == Path.join(dir, "notebook.db")
    end
  end

  describe "the files directory" do
    @tag doc: """
         Pins the boot-time creation: the directory `FILES_PATH` names exists
         after the config phase, before anything is started, and the same path
         lands under the script context for `files_dir/1` to answer. A failure
         means the mkdir left `config/runtime.exs`, and an unwritable path would
         now surface as a `File.Error` inside some script's run instead of as
         the boot log's first line — or the key stopped mirroring the accessor.
         """
    test "FILES_PATH is created at the read and lands under the script context", %{
      files_dir: files_dir
    } do
      refute File.dir?(files_dir)

      assert release_files_dir() == files_dir
      assert File.dir?(files_dir)
    end

    test "a padded path is trimmed, as every path the file reads is", %{files_dir: files_dir} do
      System.put_env(@files_variable, "  #{files_dir}  ")

      assert release_files_dir() == files_dir
    end

    @tag doc: """
         `YmerNode.Script.Context.files_dir/1` promises scripts an absolute path,
         and this is the one environment where the value arrives from outside —
         so the file expands it, once. A failure means a relative `FILES_PATH`
         reaches every script as written, resolved against whatever cwd each
         `File` call happens to run under, and the directory created at boot and
         the one a script writes into need not be the same.
         """
    test "a relative path is expanded, so scripts are handed an absolute one", %{
      files_dir: files_dir
    } do
      System.put_env(@files_variable, Path.relative_to_cwd(files_dir, force: true))

      assert release_files_dir() == files_dir
      assert File.dir?(files_dir)
    end

    @tag doc: """
         The default is pinned off the source rather than observed, because
         observing it means creating `/data/files` on this machine, which is
         refused. A failure means the default left the compose mount: an install
         whose environment sets nothing would create its files directory where
         the host never sees it.
         """
    test "the default sits inside the mount, beside db/ and backups/" do
      assert @files_default == "/data/files"
    end
  end

  describe "the node time zone" do
    test "a zone the release knows lands under the script context" do
      System.put_env(@time_zone_variable, "Europe/Helsinki")

      assert release_time_zone() == "Europe/Helsinki"
    end

    test "a name the release does not know refuses boot, naming TZ and the value" do
      System.put_env(@time_zone_variable, "europe/helsinki")

      error = assert_raise ArgumentError, &release_time_zone/0

      assert error.message =~ "TZ must be an IANA time zone name"
      assert error.message =~ ~s("europe/helsinki")
    end

    @tag doc: """
         Guards the verbatim read. `env` trims every other variable the file
         reads, and a maintainer following its header would route TZ through
         that trim too — but libc reads TZ verbatim, so a trimmed name would
         boot a node whose scripts answer one zone while its clock and its log
         lines keep UTC. A failure means the read started trimming: the padded
         name was accepted as the zone it pads.
         """
    test "a padded name is refused rather than trimmed" do
      System.put_env(@time_zone_variable, "Europe/Helsinki ")

      error = assert_raise ArgumentError, &release_time_zone/0

      assert error.message =~ ~s("Europe/Helsinki ")
    end

    test "unset or blank writes no zone, leaving the context's default to answer" do
      assert release_time_zone() == nil

      for blank <- ["", "  "] do
        System.put_env(@time_zone_variable, blank)
        assert release_time_zone() == nil
      end
    end
  end
end
