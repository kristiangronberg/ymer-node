defmodule YmerNode.Script.Context do
  @moduledoc """
  What the node hands every run — Req, `JSON`, the notebook, secrets, the
  throttles it declares, the node's time zone, the files directory and the
  Typst renders — provided by the node rather than declared by the script.

  A script's code carries logic, not plumbing. It never opens a connection pool,
  never reads a config file and never learns where the node keeps anything: it
  calls the functions here and the node decides what they reach. That is what
  makes a script small enough to read before accepting it, and it is why the
  boundary is which scripts are accepted rather than what a running one can
  touch — see `YmerNode`'s Scripts section.

  ## HTTP

  `request/2` is Req with the node's own options merged underneath the script's,
  so the node can set a policy the script does not have to remember and a test
  can stub every outbound call at one seam. Two of the policy's options matter:
  `retry: false`, because a run is already bounded by a timeout and Req's
  default retry would spend most of it sleeping; and a receive timeout well
  inside the run's own. A script that wants retries asks for them.

  ## Secrets

  `secret/2` resolves a name through `YmerNode.Secrets` — but only a name the
  script **declared**. An undeclared name is refused rather than resolved, so
  `declarations/0` is a real list of what a script can reach and not a comment:
  a reader accepting the code sees every secret it can ask for. The value is
  read from disk at the call, so a secret set while the node runs is seen by the
  next run.

  Every refusal carries the **name** that could not be resolved, which is what
  lets a run that propagates it name the secret and the verb that sets it rather
  than answering a bare atom nobody can act on. A machine with no secrets file
  at all reads the same way as a file that does not set the name: for a
  resolution both mean "not set here", and the caller needs the name either way.

  ## Throttles

  A system that punishes bursts or repeated failures — an account that locks
  after a run of failed logins, an API with a budget of requests — is protected
  by a throttle. Declare it under `throttles` in `declarations/0`, where
  `t:YmerNode.Script.throttle/0` lists the parameters, and name it on every
  request that should pass through it with the `throttle:` option of
  `request/2`. The node keeps one throttle per name, shared by every script that
  declares the name and by every run of them, which is why two accepted scripts
  may declare one name only with the same parameters.

  A request waits for a token from the throttle's bucket at most until the run's
  deadline, and is refused at once when the requests already waiting and the
  rate say it would not get one in time. Every attempt pays a token, a retry
  included, and every response's status reaches the breaker. A refused request
  is never sent: `request/2` answers `{:error, exception}`, and the exception's
  message names the throttle, what stopped the request and — for an open
  breaker — the verb a person runs on this machine to reset it. The context
  offers no reset: a script that reaches past it into the node's own modules is
  outside the promise, and acceptance is where a reader sees it.

  A throttle guards `request/2` and nothing else: a script calling `Req` itself
  goes around it. A node that restarts forgets every throttle, so its bucket is
  full and its breaker closed again.

  ## Files

  The files directory, `files_dir/1`, is where a file crosses between the
  person and the script: what a person or their client drops there a script
  reads, and what a script writes there a person opens — a spreadsheet a
  colleague dropped in, an export another person opens. Nothing confines a
  script to it, because acceptance is the boundary rather than what a running
  script can touch (`YmerNode`'s Scripts section): it is where files are
  expected, not a wall. The node creates it at boot and never backs it up; the
  files in it are the user's, not the node's store.

  ## Typst

  `render_to_pdf/4`, `render_to_png/4` and `render_to_svg/4` render Typst markup
  with the node's policy merged underneath the script's own options: the files
  directory is the document's root, and the font store is built afresh for every
  render, so a font installed since the node started is seen by the next one. A
  script passes nothing and may override anything — a loop of many renders asks
  for `cache_fonts: true` itself, in the options after its bindings, and shares
  the node's one font store with every render asking for the same fonts: it is
  built by whichever asked first and rebuilt whenever a render asks for a
  different set.

  A render sees every font installed on the machine the node runs on, put there
  the way any application's font is, beside the four families inside the
  package's native library; a node running in a container sees what the
  container has, not what the host machine has.

  A script calling `Typst` itself goes around the policy, as one calling `Req`
  goes around the throttles: its root is the release's own directory and its
  font store is built at the first render and kept until the node restarts.

  ## The notebook

  The four functions mirror `YmerNode.Notebook`'s own surface — `execute/1`,
  `query/1`, `tables/0`, `table_schema/1` — and cross no boundary the LLM has
  not already crossed: it writes the notebook directly through the `notebook`
  tool. There is nothing here to declare, which is why `t:YmerNode.Script.declarations/0`
  has no notebook key.
  """
  alias YmerNode.Notebook
  alias YmerNode.Scripts.Throttle
  alias YmerNode.Secrets

  @default_request_options [retry: false, receive_timeout: 15_000]

  @default_render_options [cache_fonts: false]

  @enforce_keys [:script, :action, :secrets, :throttles, :deadline]
  defstruct [:script, :action, :secrets, :throttles, :deadline]

  @typedoc """
  What the node hands every run — Req, `JSON`, the notebook, secrets, the
  throttles it declares, the node's time zone, the files directory and the
  Typst renders — provided by the node rather than declared by the script. The
  struct itself carries the script's own name, the action being run, the secret
  names its declarations allow it to resolve, the throttles they declare, and
  the run's deadline as the `System.monotonic_time(:millisecond)` instant it
  falls at.

  It carries no connection, no client and no credential — those are reached
  through the functions on this module, which is what lets the node change any
  of them without touching a single script.
  """
  @type t :: %__MODULE__{
          script: String.t(),
          action: atom(),
          secrets: [String.t()],
          throttles: %{String.t() => YmerNode.Script.throttle()},
          deadline: integer()
        }

  # ─── Runtime configuration ──────────────────────────────────────────

  @doc """
  Req options the node merges under every script request
  (`config :ymer_node, YmerNode.Script.Context, :request_options`).

  Defaults to `retry: false` and a 15 s receive timeout. `config/test.exs` adds
  a `:plug` pointing at `Req.Test`, which is what lets a test stub a script's
  outbound calls without the script knowing.
  """
  def request_options do
    :ymer_node
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:request_options, @default_request_options)
  end

  @doc """
  Typst options the node merges under every script render
  (`config :ymer_node, YmerNode.Script.Context, :render_options`), beneath the
  root, which is the files directory at every render.

  Defaults to `cache_fonts: false`: the font store is built afresh for every
  render, so a font installed since the node started is seen by the next one.
  A node on a machine whose font scan is slow sets `cache_fonts: true` here,
  once, rather than in scripts synced between its user's nodes; a script that
  wants the cache for a loop still asks for it itself, § Typst above.
  """
  def render_options do
    :ymer_node
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:render_options, @default_render_options)
  end

  @doc """
  The node's time zone, as the IANA name of the zone this node runs in — read
  from `TZ` when the container boots, `Etc/UTC` when it is unset — for a script
  to name the zone it reports in without carrying one: a script synced between a
  user's nodes is the same bytes on every node, and each node answers its own. A
  script may still name any zone literally.

  Always a string, and always one every zone-aware `DateTime` function accepts,
  so a script reporting in it writes
  `DateTime.shift_zone(instant, Context.time_zone(context))`. The value is
  `config :ymer_node, YmerNode.Script.Context, :time_zone`: `config/runtime.exs`
  writes it from `TZ` in the prod environment alone, refusing boot on a name the
  release's zone database does not know, so a dev or test node answers
  `Etc/UTC`.
  """
  def time_zone(%__MODULE__{}), do: time_zone()

  @doc """
  What `time_zone/1` answers, for a caller holding no run context:
  `YmerNode.Schedules` reads a cron expression and an offset-less lifetime in
  this zone, and renders every time it answers in it.
  """
  def time_zone do
    :ymer_node
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:time_zone, "Etc/UTC")
  end

  @doc """
  The files directory — the one directory on this machine a script reads files
  from and writes files to, `<install>/data/files` on the host and the directory
  `FILES_PATH` names in the container — created by the node at boot, never
  backed up by it, and the user's own: what a person or their client drops there
  a script reads with `File`, and what a script writes there a person opens. No
  path sits in a script's text, so a script synced between a user's nodes is the
  same bytes on every node, and each node answers its own.

  Always an absolute path, as a string, so a script reading a file there writes
  `File.read!(Path.join(Context.files_dir(context), "issues.xlsx"))`. `File`
  and `Path` are the whole of what a script needs: sub-directories are the
  script's to make (`File.mkdir_p!/1`) and the user's to arrange. The value is
  `config :ymer_node, YmerNode.Script.Context, :files_dir` — `config/runtime.exs`
  writes it from `FILES_PATH` in the prod environment, `config/dev.exs` and
  `config/test.exs` name a directory of their own — and an absent key is a
  configuration defect this refuses by name rather than a case to default. A VM
  that runs script code outside the node has none of those environments, and
  points the key with `YmerNode.Script.Harness.put_files_dir/1`.
  """
  def files_dir(%__MODULE__{}) do
    :ymer_node
    |> Application.get_env(__MODULE__, [])
    |> Keyword.fetch(:files_dir)
    |> case do
      {:ok, directory} ->
        directory

      :error ->
        raise ArgumentError,
              "no files directory is configured: `config :ymer_node, " <>
                "YmerNode.Script.Context, files_dir:` is unset — the release writes " <>
                "it from FILES_PATH, dev and test each name their own, and a VM running " <>
                "scripts outside the node points it with " <>
                "YmerNode.Script.Harness.put_files_dir/1"
    end
  end

  # ─── Public API ─────────────────────────────────────────────────────

  @doc """
  Makes one HTTP request through Req, with the node's `request_options/0` merged
  underneath the script's own — so a script can override any of them and gets a
  sane policy when it overrides none.

  `throttle: name` sends the request through the throttle the script declared
  under that name, § Throttles above: it waits for a token first, and its status
  reaches the throttle's breaker, every retried attempt's included.

  Answers Req's own `{:ok, %Req.Response{}} | {:error, exception}` — the
  exception a `YmerNode.Scripts.Throttle.Error` when a throttle refused the
  request before it was sent. A script that wants only the body matches on
  `%{status: 200, body: body}`.
  """
  # Plugins run first, as `Req.new/1` runs them, so a plugin's options are
  # registered before the merge validates them; the throttle's own option is
  # registered by `attach/3` for the same reason.
  def request(%__MODULE__{throttles: throttles, deadline: deadline}, options)
      when is_list(options) do
    {plugins, options} = request_options() |> Keyword.merge(options) |> Keyword.pop(:plugins, [])

    Req.new(plugins: plugins)
    |> Throttle.attach(throttles, deadline)
    |> Req.request(options)
  end

  @doc """
  Renders Typst markup to a PDF — `Typst.render_to_pdf/3` with the node's policy
  merged underneath the script's own options, § Typst above.

  Answers the package's own `{:ok, binary} | {:error, message}`, so a script
  rendering a report writes
  `{:ok, pdf} = Context.render_to_pdf(context, markup, summary: Typst.Format.escape(summary))`
  and puts the bytes where the person opens them — a binding interpolated as
  markup is escaped first, or a `#` in the text fails the render.
  """
  def render_to_pdf(%__MODULE__{} = context, markup, bindings \\ [], options \\ [])
      when is_binary(markup) and is_list(bindings) and is_list(options) do
    Typst.render_to_pdf(markup, bindings, render_policy(context, options))
  end

  @doc """
  Renders Typst markup to one PNG per page — `Typst.render_to_png/3` with the
  node's policy merged underneath the script's own options, § Typst above.

  Answers the package's own `{:ok, [binary]} | {:error, message}`, one binary
  per page in order, so a script counting pages writes
  `{:ok, pages} = Context.render_to_png(context, markup)`.
  """
  def render_to_png(%__MODULE__{} = context, markup, bindings \\ [], options \\ [])
      when is_binary(markup) and is_list(bindings) and is_list(options) do
    Typst.render_to_png(markup, bindings, render_policy(context, options))
  end

  @doc """
  Renders Typst markup to one SVG per page — `Typst.render_to_svg/3` with the
  node's policy merged underneath the script's own options, § Typst above.

  Answers the package's own `{:ok, [String.t()]} | {:error, message}`, one
  string per page in order, so a script embedding the first page writes
  `{:ok, [first | _rest]} = Context.render_to_svg(context, markup)`.
  """
  def render_to_svg(%__MODULE__{} = context, markup, bindings \\ [], options \\ [])
      when is_binary(markup) and is_list(bindings) and is_list(options) do
    Typst.render_to_svg(markup, bindings, render_policy(context, options))
  end

  # The node's policy behind the three renders: `root_dir` read from the context,
  # the rest `render_options/0`, merged underneath the script's own so any of it
  # can be overridden — `request/2`'s order, and `files_dir/1` raises here
  # before the package is called when no directory is configured.
  defp render_policy(%__MODULE__{} = context, options) do
    render_options()
    |> Keyword.put(:root_dir, files_dir(context))
    |> Keyword.merge(options)
  end

  @doc """
  Resolves a declared secret by name.

  `{:error, {:secret_undeclared, name}}` when `declarations/0` does not list the
  name — the declaration is enforced, not documentation — and
  `{:error, {:secret_not_found, name}}` when it is declared but not set on this
  machine. Both carry the name, so the two branches are symmetric and a run that
  hands either back can say which secret it wanted.
  """
  def secret(%__MODULE__{secrets: declared}, name) when is_binary(name) do
    if name in declared, do: resolve(name), else: {:error, {:secret_undeclared, name}}
  end

  # A missing file and a file without the name are one answer here: both mean
  # the secret is not set on this machine, and the name is what the caller needs
  # in either case. Anything else `YmerNode.Secrets` refuses — a permissive
  # file, an unreadable one — passes through as it came, because those are about
  # the file rather than about this secret.
  defp resolve(name) do
    case Secrets.get(name) do
      {:ok, value} -> {:ok, value}
      {:error, :secret_not_found} -> {:error, {:secret_not_found, name}}
      {:error, :secrets_file_missing} -> {:error, {:secret_not_found, name}}
      {:error, other} -> {:error, other}
    end
  end

  @doc "Runs one DDL/DML statement against the notebook — `YmerNode.Notebook.execute/1`."
  def execute(%__MODULE__{}, sql) when is_binary(sql), do: Notebook.execute(sql)

  @doc "Runs one read-only statement against the notebook — `YmerNode.Notebook.query/1`."
  def query(%__MODULE__{}, sql) when is_binary(sql), do: Notebook.query(sql)

  @doc "Lists the notebook's user tables — `YmerNode.Notebook.tables/0`."
  def tables(%__MODULE__{}), do: Notebook.tables()

  @doc "Full schema for one notebook table — `YmerNode.Notebook.table_schema/1`."
  def table_schema(%__MODULE__{}, table) when is_binary(table), do: Notebook.table_schema(table)
end
