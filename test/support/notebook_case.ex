defmodule YmerNode.NotebookCase do
  @moduledoc """
  Test setup for code that touches `YmerNode.Notebook.Repo`.

  Owns the repo's sandbox. SQLite is single-writer, so `async: true` is NOT
  supported — `use YmerNode.NotebookCase` without the async flag. Each test runs
  in a sandbox transaction, so the DDL a test issues (`CREATE TABLE`, the `_meta`
  table) is rolled back at the end of it.
  """
  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      alias YmerNode.Notebook
      alias YmerNode.Notebook.Repo
    end
  end

  setup tags do
    pid = Sandbox.start_owner!(YmerNode.Notebook.Repo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end
end
