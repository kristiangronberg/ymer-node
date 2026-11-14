defmodule YmerNode.Scripts.Libraries do
  @moduledoc """
  The rules that keep the graph between scripts and the libraries they declare
  true, each with the refusal that names what is wrong and the call that fixes
  it. Pure: every function here is handed what it judges, so the same rule reads
  the same whether the loader runs it against this boot's facts or
  `YmerNode.Scripts` runs it against the rows.

  A script **declares** a library by name with a requirement
  (`t:YmerNode.Script.declarations/0`); every script declaring a library is one
  of its **dependents**. Three rules follow, and each refuses rather than
  repairs, because the repair would destroy or silently break code that may be
  the only copy:

  - a script is **held** only while every library it declares is held — loaded
    by this boot, at a version inside the script's requirement
    (`check_held/3`);
  - a library with dependents is not removed (`check_removable/2`);
  - a library is not moved to a version outside a dependent's requirement
    (`check_in_range/3`).

  Requirements are Elixir's own, read and matched by `Version`.

  A script refused for a library is judged again only when it is: a write of
  that script, or a boot. So a script kept Broken at boot for a library stays
  Broken after the library is fixed or created, and each such refusal says to
  store the script again (`create` if it is new, `update` if it is stored,
  which accepts the same code) or restart the node. A run refused for a library
  is the other case: the script is loaded, so its refusal says it runs again
  once the library is held (`check_held/4` with `:run`).
  """

  @doc """
  Whether every library `declared` names is held: present in `held` as a loaded
  library at a version its requirement matches.

  `declared` maps a library's name to its requirement, as a script's
  declarations carry it. `held` maps a name to that row's facts as this boot
  knows them — `kind`, `version`, `loaded?` and `error` — and a name it lacks is
  a library this node does not hold. Answers `:ok`, or the refusal for the first
  library by name that is not held: `{:error, {:library_missing, detail}}`,
  `{:error, {:library_broken, detail}}` or `{:error, {:library_out_of_range,
  detail}}`, the detail naming the script, the library, the requirement and the
  fix. `at` says whose fix it is: `:store`, the default, tells the script to be
  stored again; `:run`, for a loaded script refused at its run, says it runs
  again once the library is held.
  """
  def check_held(script, declared, held, at \\ :store)
      when is_binary(script) and is_map(declared) and is_map(held) and at in [:store, :run] do
    declared
    |> Enum.sort()
    |> Enum.find_value(:ok, fn {name, requirement} ->
      held_fault(script, name, requirement, Map.get(held, name), at)
    end)
  end

  @doc """
  The scripts that declare `library`, each with its requirement, ordered by
  name. `rows` are `{script_name, declarations}` pairs, the declarations as a row
  stores them, string-keyed.

  ## Examples

      iex> rows = [{"sync", %{"libraries" => %{"crosskey" => "~> 1.0"}}}, {"hex", %{}}]
      iex> YmerNode.Scripts.Libraries.dependents("crosskey", rows)
      [{"sync", "~> 1.0"}]

  """
  def dependents(library, rows) when is_binary(library) and is_list(rows) do
    rows
    |> Enum.flat_map(fn {script, declarations} ->
      case declarations |> Map.get("libraries", %{}) |> Map.fetch(library) do
        {:ok, requirement} -> [{script, requirement}]
        :error -> []
      end
    end)
    |> Enum.sort()
  end

  @doc """
  Answers `:ok` for a library no script declares, and
  `{:error, {:library_in_use, detail}}` naming every dependent otherwise.

  ## Examples

      iex> YmerNode.Scripts.Libraries.check_removable("crosskey", [])
      :ok

      iex> {:error, {:library_in_use, detail}} =
      ...>   YmerNode.Scripts.Libraries.check_removable("crosskey", [{"sync", "~> 1.0"}])
      iex> detail =~ "declared by sync (~> 1.0)"
      true

  """
  def check_removable(library, []) when is_binary(library), do: :ok

  def check_removable(library, dependents) when is_binary(library) and is_list(dependents) do
    {:error,
     {:library_in_use,
      "#{library} is declared by #{render(dependents)} — update those scripts to stop " <>
        "declaring it, or remove them, first"}}
  end

  @doc """
  Answers `:ok` when `version` is inside every dependent's requirement, and
  `{:error, {:requirement_broken, detail}}` naming each dependent it falls
  outside.

  ## Examples

      iex> YmerNode.Scripts.Libraries.check_in_range("crosskey", "1.4.0", [{"sync", "~> 1.0"}])
      :ok

      iex> {:error, {:requirement_broken, detail}} =
      ...>   YmerNode.Scripts.Libraries.check_in_range("crosskey", "2.0.0", [{"sync", "~> 1.0"}])
      iex> detail =~ "outside what sync (~> 1.0) require"
      true

  """
  def check_in_range(library, version, dependents)
      when is_binary(library) and is_binary(version) and is_list(dependents) do
    case Enum.reject(dependents, fn {_script, requirement} ->
           Version.match?(version, requirement)
         end) do
      [] ->
        :ok

      outside ->
        {:error,
         {:requirement_broken,
          "#{library} #{version} is outside what #{render(outside)} require — widen " <>
            "those requirements first, or keep the version in range"}}
    end
  end

  defp held_fault(script, name, requirement, nil, at) do
    {:error,
     {:library_missing,
      "#{script} declares the library #{name} (#{requirement}), which this node does not " <>
        "hold — create or import #{name}, " <> fix(script, name, at)}}
  end

  # The kind first: a row of the other kind is the fault whatever its state.
  defp held_fault(script, name, requirement, %{kind: kind}, _at)
       when kind not in [:library, nil] do
    {:error,
     {:library_missing,
      "#{script} declares the library #{name} (#{requirement}), and #{name} here is a " <>
        "#{kind} — a script cannot be declared as a library"}}
  end

  # A failed compile's facts carry the kind only where the code still parses, so
  # this names the row, not a library.
  defp held_fault(script, name, _requirement, %{loaded?: false, error: {reason, detail}}, at) do
    {:error,
     {:library_broken,
      "#{script} declares the library #{name}, and the row #{name} could not compile " <>
        "here (#{reason}: #{detail}) — fix #{name}, " <> fix(script, name, at)}}
  end

  defp held_fault(script, name, requirement, %{version: version}, at) do
    if Version.match?(version, requirement) do
      nil
    else
      {:error,
       {:library_out_of_range,
        "#{script} declares the library #{name} #{requirement}, and this node holds " <>
          "#{name} #{version} — update #{name} into range or change the requirement, " <>
          fix(script, name, at)}}
    end
  end

  # At a run the script itself is loaded, so it runs again as soon as the
  # library is held; storing it while the library is not would make it Broken.
  defp fix(script, name, :run), do: "#{script} runs again once #{name} is held"
  defp fix(script, _name, :store), do: store_again(script)

  defp store_again(script) do
    "then store #{script} again — with `create` if it is new, or `update` if it is " <>
      "stored, which accepts the same code; a stored one is otherwise checked again " <>
      "only when the node restarts"
  end

  defp render(dependents),
    do:
      Enum.map_join(dependents, ", ", fn {script, requirement} -> "#{script} (#{requirement})" end)
end
