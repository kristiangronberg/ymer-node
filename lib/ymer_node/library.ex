defmodule YmerNode.Library do
  @moduledoc """
  A library is shared Elixir code a script declares and calls — authored,
  checked and accepted like a script, held at exactly the code accepted, with no
  actions and never run.

  It is the contract such code implements: a description, a version, and
  whatever public functions the scripts that declare it call.

  ## Writing one

      defmodule Library.Crosskey do
        use YmerNode.Library

        alias YmerNode.Script.Context

        @impl true
        def description, do: "Request options every Crosskey script shares."

        @impl true
        def version, do: "1.0.0"

        @doc "Basic-auth request options for Crosskey's servers, from the calling script's secrets."
        def account(context) do
          {:ok, password} = Context.secret(context, "CROSSKEY_PASSWORD")
          [auth: {:basic, "svc:" <> password}, headers: [accept: "application/json"]]
        end
      end

  A library sits under `Library.<Name>`, and its name is derived the way a
  script's is: `Library.Crosskey` is `crosskey`. Every module it defines sits
  under that tree. Libraries and scripts share one name space, so a node holds
  `Script.Crosskey` or `Library.Crosskey`, never both. It is checked, created,
  updated, exported and imported through the same doors a script is
  (`YmerNode.Script` § The loop, § Sharing a script), and `scripts describe`
  shows its version, its API and the scripts that declare it.

  ## Calling one

  A script names each library it calls in the `libraries` of its declarations,
  with a requirement on the library's version (`t:YmerNode.Script.declarations/0`),
  and calls it by module: `Library.Crosskey.account(context)`. The library is
  handed the calling script's context, so `YmerNode.Script.Context.secret/2`
  resolves only the names the calling script declares; a library declares no
  secrets and no throttles of its own. A library calls no other library, and
  the compiler refuses one that names another.

  ## What the node keeps true

  - A script is refused at acceptance while a library it declares is missing,
    held at a version outside the script's requirement, or Broken, and a boot
    that meets the same keeps the script Broken with the same text. Boot
    compiles every library before any script. A script that `require`s or
    `import`s such a library, or builds one of its structs, fails its own
    compile first, so it is refused, or kept Broken, with the compiler's error
    instead.
  - A script kept Broken for a library stays Broken once the library is fixed
    or created: nothing checks it again until it is stored again (`create` if
    it is new, `update` if it is stored, which accepts the same code) or the
    node restarts. A loaded script whose library stops being held is the other
    case: its runs are refused with the library's own reason, and it runs again
    once the library is held, with nothing stored.
  - A library is not removed while a script declares it, and not updated to a
    version outside a script's requirement. Each refusal names the scripts and
    the call that resolves it.
  - A library is not replaced or removed while a run of any script declaring it
    is in flight: the purge would kill that run inside the library's code.
  - An update within every requirement lands without recompiling the scripts,
    for their calls: a call to a library function reaches the library by module
    name at the moment it is made. A macro, an `import`ed macro or a struct a
    script took from the library is fixed when that script compiles, and keeps
    the old library's form until the script is stored again or the node
    restarts. Keep a library's macros and structs stable within a requirement's
    range, or move its version outside it and store the dependents again.

  ## Its documentation is its API

  `scripts describe` renders a library's public functions from its own docs —
  each function with a `@doc`, by its signature and its text — so a script's
  author learns the calls without reading the code. Write a `@doc` on every
  function a script should call; one without stays callable and unlisted.
  """
  @contract 1

  @doc "One line saying what the library is for."
  @callback description() :: String.t()

  @doc """
  The author's version of this code, a `Version` string, as for a script
  (`c:YmerNode.Script.version/0`): a script's requirement is checked against it.
  """
  @callback version() :: String.t()

  defmacro __using__(_opts) do
    quote do
      @behaviour YmerNode.Library

      @doc false
      def __library_contract__, do: unquote(@contract)
    end
  end

  @doc """
  The library contract version this node speaks, which `use` stamps into every
  library this node compiles.
  """
  def contract, do: @contract

  @doc """
  The callbacks a library must export, as `{name, arity}` pairs, checked by
  `YmerNode.Scripts.Compiler` as a script's are.
  """
  def callbacks, do: [{:description, 0}, {:version, 0}]
end
