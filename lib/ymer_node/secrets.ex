defmodule YmerNode.Secrets do
  @moduledoc """
  The values a script resolves by name — one file of `NAME=value` lines,
  outside every database.

  ## Why a file, and not a table

  `node.db` is rebuildable by construction, and the durability rule (`YmerNode`)
  admitted it on exactly that ground: deleting it costs nothing a boot does not
  put back, and `mix ecto.drop` is an ordinary development move. A secrets table
  would make one row of it precious and the rule would have to grow an
  exception. A file beside the databases leaves the rule intact — the store
  stays the one thing worth keeping, and a lost `secrets.env` costs a re-set
  rather than a restore.

  It is also hand-editable, in the dotenv shape an install's `.env` already
  uses, which is what an operator reaches for when no CLI is to hand.

  ## Read at every resolution

  Nothing is cached. A secret set while the node runs is seen by the next run,
  with no restart, because every `get/1` opens the file. The registry is small
  and a run is already crossing a network, so the read costs nothing worth
  saving.

  Parsing is deliberately small: a blank line and a `#`-opened line are skipped,
  the FIRST `=` splits the line, the name is trimmed, and the value is trimmed
  and then unwrapped once if it is wholly single- or double-quoted. There is no
  escape grammar and no interpolation — a value needing either belongs in a file
  the script reads, not in a line here. A later duplicate name wins, which is
  what a hand-edit appending a line expects.

  ## Mode is checked, never assumed

  `set/2` creates the file `0600` and chmods it back to `0600` on every write.
  `get/1` and `list/0` refuse a file any group or other bit can read —
  `{:error, {:secrets_file_permissive, "644"}}` — because a secret in a
  world-readable file is not one, and an operator has to be told rather than
  quietly served. The check is `Bitwise.band(mode, 0o077) == 0`, so `0600` and
  `0400` both pass.

  ## Every write is a rename

  `set/2` and `unset/1` rewrite the whole file, so a write interrupted part-way
  — a kill, a stop signal during a deploy, a full disk — would take every other
  secret with it and not only the one being changed. A neighbouring temp file
  is created empty, chmodded `0600`, written, and then renamed over the target:
  a rename within one directory is atomic, so a reader sees the old file or the
  new one and never half of either. Chmod before the write and not after it,
  because a file is created at the process umask, and one written first would
  hold every value readable for as long as the write took.

  No value leaves this module except through `get/1`. `list/0` answers names,
  errors name the secret and never its value, and nothing here logs.
  """
  import Bitwise, only: [band: 2]

  @name_pattern ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/

  # ─── Runtime configuration ──────────────────────────────────────────

  @doc """
  Absolute path of the secrets file (`config :ymer_node, YmerNode.Secrets,
  :path`).

  `Keyword.fetch!` and not a default: every environment sets it —
  `config/prod.exs` carries `/data/secrets.env`, `config/runtime.exs` overrides
  it from `SECRETS_PATH`, dev and test point at the checkout root — and a node
  that cannot say where its secrets live must fail loudly rather than invent a
  path and write a file there.
  """
  def path do
    :ymer_node
    |> Application.get_env(__MODULE__, [])
    |> Keyword.fetch!(:path)
  end

  # ─── Public API ─────────────────────────────────────────────────────

  @doc """
  Resolves one secret by name.

  `{:error, :secret_not_found}` when the file has no such name — the same answer
  a file with the name commented out gives, because both mean "not set here".
  """
  def get(name) when is_binary(name) do
    with {:ok, entries} <- read_entries() do
      case Map.fetch(entries, name) do
        {:ok, value} -> {:ok, value}
        :error -> {:error, :secret_not_found}
      end
    end
  end

  @doc "Every name the file sets, sorted. Names only — never a value."
  def list do
    with {:ok, entries} <- read_entries(), do: {:ok, entries |> Map.keys() |> Enum.sort()}
  end

  @doc """
  Writes one secret, creating the file `0600` on the first set.

  A name already in the file is replaced in place, so hand-written comments,
  blank lines and ordering survive a set; a new name is appended. The whole
  file is rewritten, which is why `set/2` refuses a value carrying a newline:
  one line per secret is the format's only structural rule.
  """
  def set(name, value) when is_binary(name) and is_binary(value) do
    with :ok <- validate_name(name),
         :ok <- validate_value(value),
         {:ok, lines} <- read_lines_for_write() do
      write_lines(replace_or_append(lines, name, value))
    end
  end

  @doc """
  Removes one secret. `{:error, :secret_not_found}` when the name is not set,
  so an unset that changed nothing says so rather than reporting success.
  """
  def unset(name) when is_binary(name) do
    with :ok <- validate_name(name),
         {:ok, lines} <- read_lines_for_write() do
      case Enum.split_with(lines, &sets?(&1, name)) do
        {[], _kept} -> {:error, :secret_not_found}
        {_dropped, kept} -> write_lines(kept)
      end
    end
  end

  # ─── Private ────────────────────────────────────────────────────────

  defp validate_name(name) do
    if Regex.match?(@name_pattern, name), do: :ok, else: {:error, :invalid_secret_name}
  end

  defp validate_value(value) do
    if String.contains?(value, "\n"), do: {:error, :invalid_secret_value}, else: :ok
  end

  defp read_entries do
    with {:ok, lines} <- read_lines_for_read() do
      {:ok,
       lines
       |> Enum.map(&parse_line/1)
       |> Enum.reject(&is_nil/1)
       |> Map.new()}
    end
  end

  # The read path insists on a file; the write path does not, because `set/2`
  # is what creates it. Both refuse a permissive mode, so a hand-chmod cannot
  # be papered over by writing through it.
  defp read_lines_for_read do
    file_path = path()

    with {:ok, stat} <- stat(file_path),
         :ok <- check_mode(stat) do
      read_lines(file_path)
    end
  end

  defp read_lines_for_write do
    file_path = path()

    case stat(file_path) do
      {:ok, stat} -> with :ok <- check_mode(stat), do: read_lines(file_path)
      {:error, :secrets_file_missing} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  defp stat(file_path) do
    case File.stat(file_path) do
      {:ok, stat} -> {:ok, stat}
      {:error, :enoent} -> {:error, :secrets_file_missing}
      {:error, posix} -> {:error, {:secrets_file_unreadable, posix}}
    end
  end

  defp check_mode(%File.Stat{mode: mode}) do
    if band(mode, 0o077) == 0 do
      :ok
    else
      {:error, {:secrets_file_permissive, mode |> band(0o777) |> Integer.to_string(8)}}
    end
  end

  defp read_lines(file_path) do
    case File.read(file_path) do
      {:ok, contents} -> {:ok, lines(contents)}
      {:error, posix} -> {:error, {:secrets_file_unreadable, posix}}
    end
  end

  # A file ends with a newline, so splitting on it yields one empty element
  # past the last line. That one is the terminator and not a line, and it is
  # the ONLY empty element dropped: an operator's blank line between two groups
  # is a line, and it survives a rewrite the way a comment does.
  defp lines(contents) do
    split = String.split(contents, "\n")
    if List.last(split) == "", do: Enum.drop(split, -1), else: split
  end

  # Never into the live file: the whole file is rewritten on every set and every
  # unset, so a write that stopped half-way would lose every secret rather than
  # the one being changed. Same directory, so the rename is within one
  # filesystem and therefore atomic; created empty and chmodded `0600` before a
  # byte of content reaches it, so no value ever sits under the mode the umask
  # gave the file; removed again on any failure, so a refused write leaves
  # nothing behind.
  defp write_lines(lines) do
    file_path = path()
    directory = Path.dirname(file_path)
    File.mkdir_p!(directory)
    temp_path = temp_path(directory, file_path)

    with :ok <- File.write(temp_path, ""),
         :ok <- File.chmod(temp_path, 0o600),
         :ok <- File.write(temp_path, contents(lines)),
         :ok <- File.rename(temp_path, file_path) do
      :ok
    else
      {:error, posix} ->
        File.rm(temp_path)
        {:error, {:secrets_file_unreadable, posix}}
    end
  end

  # Every line the read kept, terminated — and an emptied file is empty rather
  # than one blank line, so the next set does not begin with one.
  defp contents([]), do: ""
  defp contents(lines), do: Enum.join(lines, "\n") <> "\n"

  defp temp_path(directory, file_path) do
    Path.join(directory, ".#{Path.basename(file_path)}.#{System.unique_integer([:positive])}.tmp")
  end

  defp replace_or_append(lines, name, value) do
    line = "#{name}=#{value}"

    if Enum.any?(lines, &sets?(&1, name)) do
      Enum.map(lines, &replace_setting(&1, name, line))
    else
      lines ++ [line]
    end
  end

  defp replace_setting(existing, name, line) do
    if sets?(existing, name), do: line, else: existing
  end

  defp sets?(line, name) do
    case parse_line(line) do
      {^name, _value} -> true
      _other -> false
    end
  end

  defp parse_line(line) do
    trimmed = String.trim(line)

    if trimmed == "" or String.starts_with?(trimmed, "#") do
      nil
    else
      split_entry(trimmed)
    end
  end

  defp split_entry(trimmed) do
    case String.split(trimmed, "=", parts: 2) do
      [name, value] -> entry(String.trim(name), String.trim(value))
      [_no_equals] -> nil
    end
  end

  defp entry(name, value) do
    if Regex.match?(@name_pattern, name), do: {name, unquote_value(value)}
  end

  # One unwrap, and only when the quotes wrap the whole value: `PASS="a b"` is
  # `a b`, while `PASS=say "hi"` keeps its inner quotes. Anything cleverer needs
  # an escape grammar, which this format does not have.
  defp unquote_value(value) do
    cond do
      wrapped?(value, "\"") -> String.slice(value, 1..-2//1)
      wrapped?(value, "'") -> String.slice(value, 1..-2//1)
      true -> value
    end
  end

  defp wrapped?(value, quote_character) do
    byte_size(value) >= 2 and String.starts_with?(value, quote_character) and
      String.ends_with?(value, quote_character)
  end
end
