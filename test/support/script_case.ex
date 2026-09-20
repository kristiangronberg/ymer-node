defmodule YmerNode.ScriptCase do
  @moduledoc """
  Test support for cases that compile script code into this VM.

  Compiled modules are **VM-global** and the suite runs cases concurrently, so
  two cases compiling `Script.Fixture` would silently take each other's module.
  `fixture/1` answers a name carrying `System.unique_integer/1`, which makes
  every case's module tree its own — and that is what lets a case using this
  template stay `async: true`.

  Teardown purges **only the tree the case compiled**, never every loaded
  `Script.*` module: a blanket purge would unload a concurrent case's module
  between its compile and its call. Register a tree with `purge_on_exit/1`, or
  let `compile_fixture/1` do it.

  A case that also needs the node database uses `YmerNode.DataCase` instead and
  calls `purge_on_exit/1` by hand — the two templates do not compose, and
  `DataCase` cannot be async anyway.
  """
  use ExUnit.CaseTemplate

  alias YmerNode.Scripts.Compiler

  using do
    quote do
      import YmerNode.ScriptCase
    end
  end

  @default_body """
    @impl true
    def description, do: "a fixture script"

    @impl true
    def actions, do: %{noop: %{description: "does nothing", properties: %{}, write: false}}

    @impl true
    def declarations, do: %{hosts: [], url_action: nil, secrets: []}

    @impl true
    def run(:noop, _args, _context), do: {:ok, %{}}
  """

  @doc """
  Code for one fixture script under a name unique to this case, with its derived
  name and top module.

  Pass a body to replace the default callbacks; pass `use: false` to leave out
  the `use YmerNode.Script` line, which is how the missing-contract refusal is
  exercised.
  """
  def fixture(options \\ []) do
    body = Keyword.get(options, :body, @default_body)
    segment = "Fixture#{System.unique_integer([:positive])}"
    use_line = if Keyword.get(options, :use, true), do: "  use YmerNode.Script\n\n", else: ""

    %{
      code: "defmodule Script.#{segment} do\n#{use_line}#{body}end\n",
      name: Macro.underscore(segment),
      module: Module.concat(["Script", segment])
    }
  end

  @doc "Purges one script's module tree when the case ends."
  def purge_on_exit(top_module) when is_atom(top_module) do
    ExUnit.Callbacks.on_exit(fn -> Compiler.purge(top_module) end)
    top_module
  end

  @doc """
  Compiles a fixture and registers its tree for purge, answering the compiler's
  own `{:ok, map}` or `{:error, reason}` unchanged.
  """
  def compile_fixture(%{code: code, module: module}) do
    purge_on_exit(module)
    Compiler.compile(code)
  end
end
