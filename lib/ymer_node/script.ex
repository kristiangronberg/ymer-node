defmodule YmerNode.Script do
  @moduledoc """
  The contract a script implements — its description, its actions and their
  read/write marks, its declarations — and the version `use YmerNode.Script`
  stamps into its row.

  ## It mirrors `Wymcp.Tool` on purpose

  A script is served to a worker through the `scripts` tool, and `describe`
  renders its actions the way `help` renders a tool's. Reusing the framework's
  action shape — `description`, `properties`, `required`, an optional `notes` —
  means one shape to learn and one renderer to write. Two keys are the node's
  own, because the framework has nowhere to put them: `write`, which marks an
  action that changes something outside the node, and an optional `timeout`.

  ## Why callbacks and not module attributes

  A script's code is compiled at runtime with `Code.compile_string/2`, and a
  plain module attribute is gone by the time the module is loaded — only a
  function, or an attribute registered with `persist: true`, survives. Callbacks
  are the readable surface, so they are the whole contract; `use` adds one more
  generated function, `__script_contract__/0`, which is how a row records the
  version it was written against.

  ## The version

  `use YmerNode.Script` stamps `contract/0`'s value into the row at write. A row
  whose contract this node does not speak is refused — at write, and after an
  upgrade at boot — with a message naming both versions. There is one version
  today; the mechanism exists so the second one is a refusal an operator can
  read rather than a crash inside a callback that moved.

  ## Writing one

      defmodule Script.Hex do
        use YmerNode.Script

        @impl true
        def description, do: "Reads package metadata from hex.pm."

        @impl true
        def actions do
          %{
            package: %{
              description: "Metadata for one hex package",
              properties: %{"name" => %{"type" => "string"}},
              required: ["name"],
              write: false
            }
          }
        end

        @impl true
        def declarations, do: %{hosts: ["hex.pm"], url_action: nil, secrets: []}

        @impl true
        def run(:package, %{"name" => name}, context) do
          YmerNode.Script.Context.request(context, url: "https://hex.pm/api/packages/\#{name}")
        end
      end

  Every module the code defines must sit under `Script.<Name>`, and the script's
  name is derived from that top module — `Script.Hex` is `hex`, `Script.ReqTest`
  is `req_test` — `YmerNode.Scripts.Compiler` owns both rules and refuses at the
  parse, before anything compiles.

  ## The loop

  Write the module, then `script_author check` it: the node compiles the code
  and reports the derived name, the description, every action's schema, the
  declarations and any compile warnings — writing nothing, every refusal the
  one `create` would give, and `existing: true` meaning a script of that name
  is already here and `update` is the call instead. `script_author create`
  makes it a script the node holds, accepted at exactly those bytes.
  `scripts describe` shows what the node made of it; `scripts run` runs one
  action, bounded by the deadline `YmerNode.Scripts.Runner` states and killed
  past it. After every edit, `check` again; `update` replaces the code whole.

  ## What a script may call

  What stays callable across releases: Elixir's standard library and the
  Erlang/OTP applications this release carries, `Req` — its public functions
  and `Req.Response` — `JSON`, `YmerNode.Script.Context`, and one package per
  job in this table, each at the line its last column names:

  | Job | Use | Line |
  | --- | --- | --- |
  | Read XML — an RSS feed, a SOAP answer | sweet_xml: `SweetXml`, XPath over `:xmerl` | 0.7 |
  | Write XML — a SOAP envelope | saxy: `Saxy.XML`, then `Saxy.encode!/2` | 1.6 |
  | Read and write CSV | nimble_csv: `NimbleCSV.RFC4180`, or a separator variant `NimbleCSV.define/2` makes nested under the script's module — `NimbleCSV.define(__MODULE__.Semi, separator: ";")`, never a bare name, which lands outside the script's tree and outlives it | 1.3 |
  | Read XLSX | xlsx_reader: `XlsxReader` | 0.8 |
  | Write XLSX | elixlsx: `Elixlsx` | 0.6 |
  | Read HTML into markdown | floki: `Floki` | 0.38 |
  | Write markdown, or turn it into what a system accepts | mdex: `MDEx` | 0.13 |
  | Write a PDF — a report other people read — from Typst markup, or its pages as PNG or SVG | typst: `Typst` | 0.4 |

  Before the first script that uses a row, read the package's own docs from
  this release with `scripts info <name>` — the name is the *Use* cell's first
  word, and `req` for Req — rendered at the version this node carries, so this
  section stays a map and the depth is one call away.

  What a row cannot say:

  - **saxy** — `Saxy.XML.element/3` emits a plain string as content raw, so
    text goes through `Saxy.XML.characters/1` or a `&` ships unescaped.
  - **xlsx_reader** — `XlsxReader` reads a whole-number cell back as a float,
    `42` as `42.0`, while its `number_type: Integer` option answers `"#ERROR"`
    for a cell that is not whole.
  - **typst** — Render through the context:
    `Context.render_to_pdf(context, markup, bindings)`, or `render_to_png`
    and `render_to_svg` for its pages. The node's policy is underneath — the
    document's root is the files directory, so every path in the markup
    resolves against it, and the fonts are scanned afresh on every render,
    so one installed since the node started is seen by the next — and a
    script may pass any option the package takes, its own winning; a loop of
    many renders passes `cache_fonts: true` itself, in the options after its
    bindings: `Context.render_to_pdf(context, markup, [], cache_fonts: true)`.
    A render called on `Typst` directly goes around the policy: its root is the
    release's own directory, where nothing of the user's lives, and its font store
    is built at the first render and kept until the node restarts. The markup
    is an EEx template: text a system produced is handed in as a binding,
    never concatenated into the markup, where a `<%` in it would run as
    Elixir; a literal `<%` in the markup is written `<%%`; and a binding
    interpolated as markup goes through `Typst.Format.escape/1`, or a `#` in
    it fails the render at a line inside that text — while a binding inside
    a Typst string literal, a `#link` target or a `font:` name, is an
    identifier or a path, never escaped and never free text. A render can
    name four font families inside the package's native library — Libertinus
    Serif, New Computer Modern, New Computer Modern Math and DejaVu Sans
    Mono — and every font installed on the machine the node runs on, put
    there the way any application's font is; a node running in a container
    sees the container's fonts, not the host machine's, and one the package
    ships beside its library falls back on the node. A font Typst cannot
    find falls back silently, so a wrong name is a different-looking PDF,
    never an error. A `@preview` import fetches the package from
    packages.typst.org at render, outside the script's declared hosts and
    its throttles; it is not promised, and an offline node fails with a
    network error naming the package.

  A release carries only the Erlang/OTP applications the node's own
  dependencies need, so one in the standard distribution may be absent: the
  guide ends by listing the applications this node carries, and a call into any
  other fails at the run. The release carries more — Jason, Plug, Ecto, Finch,
  Mint and the rest of what the node itself depends on — and a script can reach
  all of it today, but none of it is promised: any of it may vanish or change at
  a release. The list is a promise about the future, not a boundary in the
  present — the boundary is which scripts are accepted (`YmerNode`'s Scripts
  section) — and `check` says nothing about a call outside it.

  Zone-aware `DateTime` functions — `DateTime.shift_zone/2`, `DateTime.now/1`,
  `DateTime.new/3` and the rest — work with IANA zone names in every script,
  with nothing to configure: the release carries a zone database and makes it
  Elixir's own. The database is the release's and its data moves with the
  node's releases, so a script names zones, never the database module. The
  node's time zone is `YmerNode.Script.Context.time_zone/1`.

  ## Secrets

  A script that reaches a system needing a secret names it in `declarations/0`
  and reads it at the run with `YmerNode.Script.Context.secret/2` — never from
  an argument, never from its own text. The value is set on the machine the
  node runs on, by a person, with the CLI — `ymer-node secrets set <NAME>`,
  the value on stdin — and it passes through no client and no script. A
  declared secret nobody set fails the run plainly, naming the secret and
  that verb.

  ## Sharing a script

  A script is its code, and sharing one is handing the code over. From a
  session, `scripts describe` with `code: true` answers it beside the
  description; on the machine, `ymer-node scripts export <name>` prints
  exactly the bytes the node holds, so `> file` there and `scripts import < file`
  elsewhere move it unchanged. On the receiving node the session runs
  `script_author check`, then `create` — acceptance is that node's own act,
  by whoever creates it there — and the person there sets whatever secrets
  `declarations/0` names. There is no second format: the module is the whole
  of it.
  """
  @contract 1

  @typedoc """
  One action's schema: wymcp's shape — `description` and `properties` mandatory,
  `required` and `notes` optional — plus the node's own `write` mark and an
  optional per-action `timeout` in milliseconds, capped by the runner.

  `write: true` says the action changes something outside this node. Nothing
  enforces it; it is what `describe` shows a worker so it can read before it
  writes, and what a human sees before accepting the code.
  """
  @type action :: %{
          required(:description) => String.t(),
          required(:properties) => %{String.t() => map()},
          required(:write) => boolean(),
          optional(:required) => [String.t()],
          optional(:notes) => String.t(),
          optional(:timeout) => pos_integer()
        }

  @typedoc """
  A script's claims and needs the node acts on: the http(s) hosts it claims for
  references with its one URL-accepting action, the secrets it resolves by name,
  and the throttles it names with their parameters.

  `hosts` are the hosts a reference is classified by — the exact host of a
  browsable link, which is often not the host the script calls (a script
  claiming `github.com` reaches `api.github.com`). `url_action` names the one
  action that accepts a uri whole under `url`; it is `nil` for a script that
  serves no references, and then `hosts` is empty too. `secrets` are the names
  the script resolves through its context, so a missing one fails plainly at the
  run instead of deep inside a request. `throttles` maps each throttle's name to
  its parameters, `t:throttle/0`, and a script that names none leaves it out.

  The map is keyed and open by design: a change-check action and a non-http
  scheme claim are later keys, and a script written today keeps working when one
  arrives.
  """
  @type declarations :: %{
          required(:hosts) => [String.t()],
          required(:url_action) => atom() | nil,
          required(:secrets) => [String.t()],
          optional(:throttles) => %{String.t() => throttle()}
        }

  @typedoc """
  A named, node-owned bound on the requests every script naming it may send — a
  token bucket (a rate per minute and a burst) and an optional breaker that stops
  sending after consecutive 401s until a cooldown passes or an operator resets
  it; one process per name, shared across scripts and runs, declared by each
  script that names it.

  `rate` is how many tokens the bucket regains in a minute and `burst` how many
  it holds, which is how many requests may start back to back. `breaker`, where
  it is given, opens after `threshold` consecutive 401 responses and stays open
  for `cooldown` milliseconds unless an operator resets it; any other status
  zeroes the count, and a throttle declared without one is a bucket alone.

  A name is lowercase letters, digits, `-` and `_`, starting with a letter or a
  digit, and it belongs to the node rather than to the script: every script
  declaring `"shared-ad"` shares one throttle, which is why accepted scripts may
  declare a name only with the same parameters. How a request passes through
  one is `YmerNode.Script.Context`'s Throttles section.
  """
  @type throttle :: %{
          required(:rate) => pos_integer(),
          required(:burst) => pos_integer(),
          optional(:breaker) => %{threshold: pos_integer(), cooldown: pos_integer()}
        }

  @doc "One line a worker reads before choosing this script."
  @callback description() :: String.t()

  @doc "Every action the script serves, keyed by its atom name."
  @callback actions() :: %{atom() => action()}

  @doc "What the node acts on: claimed hosts, the URL action, secret names, throttles."
  @callback declarations() :: declarations()

  @doc """
  Runs one action. `{:ok, term}` must be JSON-encodable, so bytes a script
  produced — a PDF, a spreadsheet — leave as a file in the files directory
  or as a request body, never as the answer. Anything else — an
  `{:error, term}`, a raise, an exit — is answered as an error naming the
  script, the action and what happened.
  """
  @callback run(action :: atom(), args :: map(), context :: YmerNode.Script.Context.t()) ::
              {:ok, term()} | {:error, term()}

  defmacro __using__(_opts) do
    quote do
      @behaviour YmerNode.Script

      @doc false
      def __script_contract__, do: unquote(@contract)
    end
  end

  @doc """
  The contract version this node speaks. A row stamped with any other is refused
  with both versions named.
  """
  def contract, do: @contract

  @doc """
  The callbacks a script must export, as `{name, arity}` pairs.

  Read at compile time rather than checked by the compiler: a behaviour's
  missing callback is a *warning* and the module still loads, so the node checks
  exports itself and refuses. `YmerNode.Scripts.Compiler` is the caller.
  """
  def callbacks, do: [{:description, 0}, {:actions, 0}, {:declarations, 0}, {:run, 3}]
end
