defmodule YmerNode.MixProject do
  use Mix.Project

  def project do
    [
      app: :ymer_node,
      version: "0.3.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      releases: releases(),
      description:
        "Headless local MCP node providing notebook, references and script capability " <>
          "to LLM workers",
      package: package(),
      name: "Ymer Node",
      docs: docs()
    ]
  end

  def application do
    [
      mod: {YmerNode.Application, []},
      # `:xmerl` is named here although sweet_xml's own application closure
      # already carries it: XPath over `:xmerl` is a promise the node makes in
      # `YmerNode.Script`'s What a script may call, so the application is the
      # node's to name rather than a dependency's side effect — the same reason
      # jsv below is a direct dependency. A release ships only the OTP
      # applications its closure names, and this line is what keeps `:xmerl`
      # in it if that closure ever stops needing it. `:eex` is named for the
      # same reason and one more: typst renders every document through
      # `EEx.eval_string/3` while its own application names no `:eex`, which
      # reaches the release today only through other dependencies' closures,
      # plug's and ecto's among them — so this line is what keeps every render
      # working if those ever stop needing it.
      extra_applications: [:logger, :xmerl, :eex]
    ]
  end

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  # The repository's published home, named once: hex requires `links`, and
  # ExDoc's `source_url` below is what gives every module page on hexdocs its
  # "view source" link. Both point here so the two cannot drift apart.
  @source_url "https://github.com/kristiangronberg/ymer-node"

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv .formatter.exs mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      extras: [{"README.md", title: "README"}, "docs/glossary.md", "docs/scripts.md"],
      groups_for_modules: [Scripts: ~r/^YmerNode\.Scripts?(\.|$)/]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:bandit, "~> 1.12.5"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:crontab, "~> 1.2"},
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, "~> 0.25"},
      {:elixlsx, "~> 0.6.0"},
      {:ex_doc, "~> 0.40.4", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4.5", only: [:dev, :test], runtime: false},
      {:floki, "~> 0.38.4"},
      # Direct although wymcp already locks it transitively: the node validates a
      # run's arguments against the action's own schema, so jsv is a dependency
      # the node relies on and therefore names. The alternative — wymcp's
      # public but undocumented `validate_schema/2` — would bind us to an
      # internal, which is a different thing from relying on a transitive
      # requirement the way the :plug comment below describes.
      {:jsv, "~> 0.22"},
      # Markdown a script turns into what a system accepts — HTML, or a tree a
      # renderer walks into a wiki's markup. A NIF: the build downloads its
      # precompiled artifact for the building machine's target, so no Rust
      # toolchain reaches the image.
      {:mdex, "~> 0.13.5"},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:mix_test_watch, "~> 1.0", only: :dev, runtime: false},
      # CSV a script reads or writes — `NimbleCSV.RFC4180` ready-made, and a
      # separator variant `NimbleCSV.define/2` builds as a module nested under
      # the script's (`__MODULE__.Semi`), so the compiler's purge reaches it.
      # Pure Elixir, with no dependencies of its own; with it in the
      # release Req's opt-in `:csv` decoder works too, which is Req's option
      # and not a promise the node makes.
      {:nimble_csv, "~> 1.3"},
      # The HTTP battery every script receives through its context. Runtime, and
      # for a caller's sake rather than the node's: a script's whole point is
      # reaching a system, and the node itself never makes an outbound call.
      {:req, "~> 0.7.4"},
      # XML a script writes — a SOAP envelope built with `Saxy.XML` and encoded
      # with `Saxy.encode!/2`. Pure Elixir, no dependencies, and in the release
      # regardless as xlsx_reader's parser; named here because writing XML is a
      # job the node promises it for.
      {:saxy, "~> 1.6"},
      {:sweet_xml, "~> 0.7.5"},
      {:typst, "~> 0.4.4"},
      # The zone database behind every zone-aware `DateTime` call a script makes,
      # made Elixir's own by one line in `config/config.exs`. The IANA data is
      # compiled into the package, so the node makes no call for zone data:
      # castore and mint serve only tz's updater, which nothing here starts —
      # mint is in the tree for Req, castore is not in it at all. The zones are
      # the IANA release this tz bundles, and IANA moves faster than tz does, so
      # a change that touches this file may take a newer tz. Should a zone in use
      # change before tz catches up, vendor a pinned IANA version instead —
      # `mix tz.download <version>` into `config :tz, :data_dir`, with
      # `:iana_version` — and move the Dockerfile's `COPY priv` above its
      # `mix deps.compile`, which today runs first.
      {:tz, "~> 0.28.2"},
      {:wymcp, "~> 0.8.4"},
      {:xlsx_reader, "~> 0.8.12"}
    ]
  end

  defp releases do
    [
      ymer_node: [
        include_executables_for: [:unix],
        # The `Docs` chunk is what `YmerNode.Scripts.Guide` renders the guide
        # from at the call; a release strips it by default, and the guide then
        # refuses rather than answering in part. Release-wide, like the strip.
        strip_beams: [keep: ["Docs"]]
      ]
    ]
  end

  defp aliases do
    [
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "credo --strict",
        "deps.audit",
        "docs --warnings-as-errors",
        "test --warnings-as-errors"
      ]
    ]
  end
end
