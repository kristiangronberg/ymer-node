defmodule YmerNode.DataCase do
  @moduledoc """
  Test setup for code that touches `YmerNode.Repo` — the node database.

  Owns that repo's sandbox, the way `YmerNode.NotebookCase` owns the notebook's;
  the two are separate because the two repos are. SQLite plus
  `Ecto.Adapters.SQL.Sandbox` does not support `async: true`, so
  `use YmerNode.DataCase` without the async flag. Each test runs inside a
  sandbox transaction, so every row it inserts is rolled back at the end of it.

  `errors_on/1` lives here because changeset assertions are this repo's staple
  and each case file would otherwise carry its own copy.
  """
  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      import Ecto.Query
      import YmerNode.DataCase

      alias YmerNode.Repo
    end
  end

  setup tags do
    pid = Sandbox.start_owner!(YmerNode.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end

  @doc """
  A changeset's errors as a map of field to messages, with each message's
  interpolations already applied — `%{title: ["should be at least 2 character(s)"]}`
  rather than the raw `"should be at least %{count} character(s)"`.
  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _whole, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
