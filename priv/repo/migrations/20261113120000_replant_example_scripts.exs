defmodule YmerNode.Repo.Migrations.ReplantExampleScripts do
  use Ecto.Migration

  require Logger

  # Remediation(inert): heals the example rows planted before the script
  # contract required version/0. plan: 2026-11-13-script-libraries
  #
  # The example scripts gained `version/0` when the script contract required
  # it, so a row planted from an earlier build no longer compiles. This brings
  # each such row to the bytes this build ships, through
  # `YmerNode.Scripts.replant_example/2`, which replaces a row only while it
  # still holds bytes a build shipped: an example the operator edited, imported
  # or removed is left as it is, and stays Broken until they store it again.
  #
  # The hashes are the sha256 of every version of each file an earlier build
  # shipped, read from the repository's history.
  @shipped %{
    "hex.exs" => [
      "b4e53093d8326d5c9d24dd17dcc6f65846ce725516318e5e4d84d76a3b8206b2",
      "d3dd3f931c89a9f7fb10b36796a215ee23d305c2f703ed40eac1797875c38ea9"
    ],
    "webpage.exs" => ["231d7fc157c62aaa26a81015f2cfa82f54bd6f4bcd010272e39beb4cc8458e1a"]
  }

  def up do
    if YmerNode.Scripts.plant_example?() do
      Enum.each(@shipped, fn {file, shipped} -> replant(file, shipped) end)
    end
  end

  # The bytes it replaced are an earlier build's, which this one does not carry.
  def down, do: :ok

  defp replant(file, shipped) do
    case YmerNode.Scripts.replant_example(file, shipped) do
      {:ok, _row} ->
        :ok

      # A claim another script holds is the operator's choice, not a fault in
      # the file, and a boot that dies over it takes the notebook with it — the
      # plant migrations log it for the same reason.
      {:error, {reason, detail}}
      when reason in [:host_claimed, :fallback_claimed, :throttle_conflict] ->
        Logger.warning(
          "the #{file} example script was not brought forward (#{reason}): #{detail} — " <>
            "it stays Broken until the claim is freed and " <>
            "#{YmerNode.Scripts.example_path(file)} is imported by hand"
        )

      {:error, {reason, detail}} ->
        raise "the #{file} example script the build ships does not compile (#{reason}): " <>
                detail
    end
  end
end
