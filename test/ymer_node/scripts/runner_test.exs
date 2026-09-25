defmodule YmerNode.Scripts.RunnerTest do
  @moduledoc """
  Fixtures reach the VM through `YmerNode.Scripts.Loader` and not through the
  compiler, because `YmerNode.Scripts.Runner.run/3` asks the loader for the
  module: a fixture compiled behind its back would not be runnable.

  Every fixture takes a name unique to its case and unloads its own tree at
  teardown, which is what keeps this module `async: true` beside the global
  module table, the one loader and the one shared `YmerNode.Scripts.Runs`
  registry — the registry is keyed by script name, so unique names keep the
  in-flight case from ever seeing another case's run.

  No case exercises the five-second metadata bound. It is the same `Task.yield`
  and `Task.shutdown` pair the deadline case already proves, and holding the
  suite for five seconds to watch the second caller of one private function
  would cost more than it pins.

  The battery cases are scripts calling the promised packages as an author
  would, so the promise is proved where it is met. The cases that touch the
  files directory write into the directory `config/test.exs` configures —
  partitioned, and created by the case since nothing creates it at boot in
  test — under names unique to the case, and remove them on exit.
  """
  use YmerNode.ScriptCase, async: true

  alias YmerNode.Scripts.Loader
  alias YmerNode.Scripts.Runner
  alias YmerNode.Scripts.Script

  doctest Runner

  @greeter """
    @impl true
    def description, do: "greets"

    @impl true
    def actions do
      %{
        greet: %{
          description: "greets by name",
          properties: %{"name" => %{"type" => "string"}},
          required: ["name"],
          write: false
        }
      }
    end

    @impl true
    def declarations, do: %{hosts: [], url_action: nil, secrets: []}

    @impl true
    def run(:greet, %{"name" => name}, _context), do: {:ok, %{"greeting" => "hello " <> name}}
  """

  @faulty """
    @impl true
    def description, do: "fails in every way there is"

    @impl true
    def actions do
      %{
        errors: %{description: "answers an error", properties: %{}, write: false},
        raises: %{description: "raises", properties: %{}, write: false},
        odd: %{description: "answers neither tuple", properties: %{}, write: false},
        opaque: %{description: "answers a pid", properties: %{}, write: false},
        naps: %{description: "sleeps, briefly", properties: %{}, write: false, timeout: 5_000},
        slow: %{description: "sleeps past its deadline", properties: %{}, write: false, timeout: 50}
      }
    end

    @impl true
    def declarations, do: %{hosts: [], url_action: nil, secrets: []}

    @impl true
    def run(:errors, _args, _context), do: {:error, :nothing_to_fetch}
    def run(:raises, _args, _context), do: raise("boom")
    def run(:odd, _args, _context), do: :neither
    def run(:opaque, _args, _context), do: {:ok, %{"pid" => self()}}

    def run(:naps, _args, _context) do
      Process.sleep(200)
      {:ok, %{"slept" => true}}
    end

    def run(:slow, _args, _context) do
      Process.sleep(1_000)
      {:ok, %{"slept" => true}}
    end
  """

  describe "run/3 — a run that works" do
    test "answers what the action produced" do
      script = accepted(@greeter)

      assert {:ok, %{"greeting" => "hello world"}} =
               Runner.run(script, "greet", %{"name" => "world"})
    end

    test "lets an argument the schema does not mention through — the wire is open-world" do
      script = accepted(@greeter)

      assert {:ok, %{"greeting" => "hello ada"}} =
               Runner.run(script, "greet", %{"name" => "ada", "extra" => 1})
    end

    test "hands the run a context carrying its declared throttles and its deadline" do
      script =
        accepted("""
          @impl true
          def description, do: "reads its own context"

          @impl true
          def actions do
            %{
              look: %{
                description: "answers the context",
                properties: %{},
                write: false,
                timeout: 2_000
              }
            }
          end

          @impl true
          def declarations do
            %{
              hosts: [],
              url_action: nil,
              secrets: [],
              throttles: %{"acct" => %{rate: 60, burst: 2}}
            }
          end

          @impl true
          def run(:look, _args, context) do
            left = context.deadline - System.monotonic_time(:millisecond)
            {:ok, %{"left" => left, "throttles" => Map.keys(context.throttles)}}
          end
        """)

      assert {:ok, %{"left" => left, "throttles" => ["acct"]}} = Runner.run(script, "look", %{})
      assert left > 0 and left <= 2_000
    end

    @tag doc: """
         A failure means the zone database is no longer Elixir's in this VM — the
         `tz` dependency or the `config :elixir, :time_zone_database` line in
         `config/config.exs` is gone — and every script asking for a named zone
         now gets `{:error, :utc_only_time_zone_database}` instead of a time.
         """
    test "a run can shift an instant into a named zone" do
      script =
        accepted("""
          @impl true
          def description, do: "reports in a named zone"

          @impl true
          def actions do
            %{shift: %{description: "shifts a fixed instant", properties: %{}, write: false}}
          end

          @impl true
          def declarations, do: %{hosts: [], url_action: nil, secrets: []}

          @impl true
          def run(:shift, _args, _context) do
            {:ok, shifted} = DateTime.shift_zone(~U[2026-09-13 08:49:36Z], "Europe/Helsinki")
            {:ok, %{"shifted" => DateTime.to_iso8601(shifted)}}
          end
        """)

      assert {:ok, %{"shifted" => "2026-09-13T11:49:36+03:00"}} = Runner.run(script, "shift", %{})
    end
  end

  describe "run/3 — the batteries a run may call" do
    @tag doc: """
         A failure means a promised package left the release or its call moved:
         the rows of the table in `YmerNode.Script`'s What a script may call
         stand on these calls. Each case is a script calling the package as an
         author would, so the guide's promise is proved where it is met.
         """
    test "a run parses CSV and dumps it back through NimbleCSV" do
      script =
        accepted("""
          @impl true
          def description, do: "round-trips CSV"

          @impl true
          def actions do
            %{
              csv: %{
                description: "parses, then dumps",
                properties: %{"text" => %{"type" => "string"}},
                required: ["text"],
                write: false
              }
            }
          end

          @impl true
          def declarations, do: %{hosts: [], url_action: nil, secrets: []}

          @impl true
          def run(:csv, %{"text" => text}, _context) do
            rows = NimbleCSV.RFC4180.parse_string(text)
            dumped = IO.iodata_to_binary(NimbleCSV.RFC4180.dump_to_iodata(rows))
            {:ok, %{"rows" => rows, "dumped" => dumped}}
          end
        """)

      text = "name,qty\nbolt,3\n\"nut, m6\",4\n"

      assert {:ok, %{"rows" => [["bolt", "3"], ["nut, m6", "4"]], "dumped" => dumped}} =
               Runner.run(script, "csv", %{"text" => text})

      assert dumped == "bolt,3\r\n\"nut, m6\",4\r\n"
    end

    test "a run writes an XLSX with Elixlsx and reads it back with XlsxReader, numbers as floats" do
      script =
        accepted("""
          @impl true
          def description, do: "round-trips a workbook in memory"

          @impl true
          def actions do
            %{xlsx: %{description: "writes, then reads", properties: %{}, write: false}}
          end

          @impl true
          def declarations, do: %{hosts: [], url_action: nil, secrets: []}

          @impl true
          def run(:xlsx, _args, _context) do
            rows = [["key", "summary"], ["ONEF-1", "hello"], ["ONEF-2", 42]]
            sheet = %Elixlsx.Sheet{name: "Issues", rows: rows}
            workbook = %Elixlsx.Workbook{sheets: [sheet]}
            {:ok, {_name, bytes}} = Elixlsx.write_to_memory(workbook, "issues.xlsx")
            {:ok, package} = XlsxReader.open(bytes, source: :binary)
            {:ok, read} = XlsxReader.sheet(package, "Issues")
            {:ok, %{"bytes" => byte_size(bytes), "rows" => read}}
          end
        """)

      assert {:ok, %{"bytes" => bytes, "rows" => rows}} = Runner.run(script, "xlsx", %{})
      assert bytes > 0
      assert [["key", "summary"], ["ONEF-1", "hello"], ["ONEF-2", 42.0]] = rows
    end

    test "a run reads a feed and a namespaced SOAP answer with SweetXml over :xmerl" do
      script =
        accepted("""
          import SweetXml

          @impl true
          def description, do: "reads XML"

          @impl true
          def actions do
            %{
              read: %{
                description: "titles from a feed, the result from a SOAP answer",
                properties: %{"feed" => %{"type" => "string"}, "soap" => %{"type" => "string"}},
                required: ["feed", "soap"],
                write: false
              }
            }
          end

          @impl true
          def declarations, do: %{hosts: [], url_action: nil, secrets: []}

          @impl true
          def run(:read, %{"feed" => feed, "soap" => soap}, _context) do
            titles = xpath(feed, ~x"//item/title/text()"ls)
            plain = xpath(soap, ~x"//*[local-name()='Result']/text()"s)

            prefixed =
              soap
              |> parse(namespace_conformant: true)
              |> xpath(~x"//soap:Body/m:PingResponse/m:Result/text()"s)

            {:ok, %{"titles" => titles, "plain" => plain, "prefixed" => prefixed}}
          end
        """)

      feed =
        ~s(<?xml version="1.0"?><rss version="2.0"><channel><title>Feed</title>) <>
          ~s(<item><title>One</title></item><item><title>Two</title></item></channel></rss>)

      soap =
        ~s(<?xml version="1.0"?>) <>
          ~s(<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body>) <>
          ~s(<m:PingResponse xmlns:m="urn:x"><m:Result>pong</m:Result></m:PingResponse>) <>
          ~s(</soap:Body></soap:Envelope>)

      assert {:ok, %{"titles" => ["One", "Two"], "plain" => "pong", "prefixed" => "pong"}} =
               Runner.run(script, "read", %{"feed" => feed, "soap" => soap})
    end

    @tag doc: """
         Pins saxy's item in the guide's list of what a row cannot say:
         content given to `Saxy.XML.element/3` as a plain string is emitted
         raw, and only `Saxy.XML.characters/1` escapes it. A failure on the
         escaped leg means Saxy's encoder changed how it treats content, and
         every SOAP body a script builds needs re-reading.
         """
    test "a run builds a SOAP envelope with Saxy.XML, escaping content through characters/1" do
      script =
        accepted("""
          @impl true
          def description, do: "builds a SOAP envelope"

          @impl true
          def actions do
            %{
              envelope: %{
                description: "an envelope around one Ping",
                properties: %{"content" => %{"type" => "string"}},
                required: ["content"],
                write: false
              }
            }
          end

          @impl true
          def declarations, do: %{hosts: [], url_action: nil, secrets: []}

          @impl true
          def run(:envelope, %{"content" => content}, _context) do
            ping = Saxy.XML.element("Ping", [], Saxy.XML.characters(content))
            body = Saxy.XML.element("soap:Body", [], [ping])
            namespace = {"xmlns:soap", "http://schemas.xmlsoap.org/soap/envelope/"}
            envelope = Saxy.XML.element("soap:Envelope", [namespace], [body])
            raw = Saxy.XML.element("Ping", [], content)
            {:ok, %{"envelope" => Saxy.encode!(envelope, version: "1.0"), "raw" => Saxy.encode!(raw)}}
          end
        """)

      assert {:ok, %{"envelope" => envelope, "raw" => raw}} =
               Runner.run(script, "envelope", %{"content" => "1 < 2 & 3"})

      assert String.starts_with?(envelope, ~s(<?xml version="1.0"?><soap:Envelope))
      assert envelope =~ "<Ping>1 &lt; 2 &amp; 3</Ping>"
      assert raw == "<Ping>1 < 2 & 3</Ping>"
    end

    test "a run reads a file from the files directory and writes one there" do
      files_dir = files_dir()

      stem = "run-#{System.unique_integer([:positive])}"
      input = Path.join(files_dir, "#{stem}-in.txt")
      output = Path.join(files_dir, "#{stem}-out.txt")
      File.mkdir_p!(files_dir)
      File.write!(input, "hello\n")
      on_exit(fn -> Enum.each([input, output], &File.rm/1) end)

      script =
        accepted("""
          alias YmerNode.Script.Context

          @impl true
          def description, do: "upcases a file into a sibling"

          @impl true
          def actions do
            %{
              upcase: %{
                description: "reads <stem>-in.txt, writes <stem>-out.txt",
                properties: %{"stem" => %{"type" => "string"}},
                required: ["stem"],
                write: false
              }
            }
          end

          @impl true
          def declarations, do: %{hosts: [], url_action: nil, secrets: []}

          @impl true
          def run(:upcase, %{"stem" => stem}, context) do
            directory = Context.files_dir(context)
            text = File.read!(Path.join(directory, stem <> "-in.txt"))
            File.write!(Path.join(directory, stem <> "-out.txt"), String.upcase(text))
            {:ok, %{"directory" => directory}}
          end
        """)

      assert {:ok, %{"directory" => ^files_dir}} = Runner.run(script, "upcase", %{"stem" => stem})
      assert File.read!(output) == "HELLO\n"
    end

    @tag doc: """
         Pins typst's item in the guide's list of what a row cannot say: a
         document importing a sibling file renders through the context with no
         keyword at all, because the node's policy roots it at the files
         directory, and system text carrying a `#` renders only through
         `Typst.Format.escape/1`. A failure on the rendered leg means the
         policy stopped reaching the package, or the package stopped resolving
         the import against the root it is given; a failure on either error leg
         means the package's line changed what the item tells an author, and
         the item needs re-reading. The unrooted leg is deliberately left on
         `Typst` itself — it is what the item says a direct call goes around,
         and moving it to the context would delete the only proof of that. The
         PNG render is the page counter and nothing else, so a `"pages"`
         failure means the document stopped paginating, not that the import
         stopped resolving.
         """
    test "a run renders a two-file document from the files directory to a PDF with Typst" do
      files_dir = files_dir()

      stem = "report-#{System.unique_integer([:positive])}"
      template = Path.join(files_dir, "#{stem}-template.typ")
      output = Path.join(files_dir, "#{stem}.pdf")
      File.mkdir_p!(files_dir)
      File.write!(template, ~s|#let banner(body) = align(center, text(size: 18pt, body))\n|)
      on_exit(fn -> Enum.each([template, output], &File.rm/1) end)

      script =
        accepted("""
          alias YmerNode.Script.Context

          @impl true
          def description, do: "renders a status report"

          @impl true
          def actions do
            %{
              report: %{
                description: "renders <stem>.pdf from a markup importing <stem>-template.typ",
                properties: %{"stem" => %{"type" => "string"}, "summary" => %{"type" => "string"}},
                required: ["stem", "summary"],
                write: false
              }
            }
          end

          @impl true
          def declarations, do: %{hosts: [], url_action: nil, secrets: []}

          @impl true
          def run(:report, %{"stem" => stem, "summary" => summary}, context) do
            directory = Context.files_dir(context)

            markup =
              Enum.join(
                [
                  ~s(#import "<%= template %>": banner),
                  "#banner[Weekly status]",
                  "<%= summary %>",
                  "#pagebreak()",
                  "= Second page"
                ],
                "\\n"
              )

            template = stem <> "-template.typ"
            escaped = [template: template, summary: Typst.Format.escape(summary)]
            {:ok, pdf} = Context.render_to_pdf(context, markup, escaped)
            {:ok, pages} = Context.render_to_png(context, markup, escaped)
            File.write!(Path.join(directory, stem <> ".pdf"), pdf)

            {:error, unrooted} = Typst.render_to_pdf(markup, escaped)
            raw = [template: template, summary: summary]
            {:error, unescaped} = Context.render_to_pdf(context, markup, raw)

            {:ok, %{"pages" => length(pages), "unrooted" => unrooted, "unescaped" => unescaped}}
          end
        """)

      arguments = %{"stem" => stem, "summary" => "Fix #login *now* [urgent]"}

      assert {:ok, %{"pages" => 2, "unrooted" => unrooted, "unescaped" => unescaped}} =
               Runner.run(script, "report", arguments)

      assert String.starts_with?(File.read!(output), "%PDF-")
      assert unrooted =~ "file not found (searched at ./#{stem}-template.typ)"
      assert unescaped =~ "unknown variable: login"
      assert unescaped =~ "Source: Fix #login *now* [urgent]"
    end
  end

  describe "run/3 — what is checked before the run" do
    test "refuses a script whose accepted hash is not its code hash" do
      script = %{accepted(@greeter) | accepted_hash: Script.hash("some other code")}

      assert {:error, {:not_accepted, message}} = Runner.run(script, "greet", %{"name" => "x"})
      assert message =~ script.name
      assert message =~ "accept it before running it"
    end

    test "refuses a script this node has not compiled" do
      code = "defmodule Script.NeverLoaded do\nend\n"
      hash = Script.hash(code)

      script = %Script{
        name: "never_loaded_#{System.unique_integer([:positive])}",
        code: code,
        code_hash: hash,
        accepted_hash: hash
      }

      assert {:error, {:not_loaded, message}} = Runner.run(script, "anything", %{})
      assert message =~ "has not been compiled since this node started"
    end

    test "refuses an action the script does not serve, naming the ones it does" do
      script = accepted(@faulty)

      assert {:error, {:unknown_action, message}} = Runner.run(script, "fetch", %{})
      assert message =~ "has no action fetch"
      assert message =~ "errors, naps, odd, opaque, raises, slow"
    end

    test "refuses arguments the action's schema rejects" do
      script = accepted(@greeter)

      assert {:error, {:invalid_args, missing}} = Runner.run(script, "greet", %{})
      assert missing =~ "property 'name' is required"

      assert {:error, {:invalid_args, wrong_type}} = Runner.run(script, "greet", %{"name" => 7})
      assert wrong_type =~ "#/name value is not of type string"
    end
  end

  describe "run/3 — every way a run can end" do
    test "answers the script's own error" do
      script = accepted(@faulty)

      assert {:error, {:script_error, message}} = Runner.run(script, "errors", %{})
      assert message =~ ":nothing_to_fetch"
    end

    test "answers a raise with the script's own line" do
      script = accepted(@faulty)

      assert {:error, {:script_raised, message}} = Runner.run(script, "raises", %{})
      assert message =~ "boom"
      assert message =~ "script:#{script.name}:"
    end

    test "refuses a return that is neither tuple" do
      script = accepted(@faulty)

      assert {:error, {:bad_return, message}} = Runner.run(script, "odd", %{})
      assert message =~ ":neither"
    end

    test "refuses a result that does not encode to JSON, naming the value" do
      script = accepted(@faulty)

      assert {:error, {:result_not_encodable, message}} = Runner.run(script, "opaque", %{})
      assert message =~ "does not encode to JSON"
      assert message =~ "#PID<"
    end

    test "kills a run that passes the deadline its action asked for" do
      script = accepted(@faulty)

      assert {:error, {:timeout, message}} = Runner.run(script, "slow", %{})
      assert message =~ "no answer in 50 ms"
    end
  end

  describe "in_flight?/1" do
    test "answers true only while a run of that script is running" do
      script = accepted(@faulty)

      refute Runner.in_flight?(script.name)

      run = Task.async(fn -> Runner.run(script, "naps", %{}) end)

      assert wait_until(fn -> Runner.in_flight?(script.name) end, 100)
      assert {:ok, %{"slept" => true}} = Task.await(run)
      assert wait_until(fn -> not Runner.in_flight?(script.name) end, 100)
    end

    @tag doc: """
         The entry belongs to the process that called `run/3`, not to either
         task inside it. A run is two tasks with the argument check between
         them, so an entry taken by a task would vanish when that task ended and
         a run in progress would read as no run at all — long enough for a write
         to pass its own check and purge the module the run is about to call.
         Asserting the PID is what tells the two designs apart: a task's
         registration would answer some other process.
         """
    test "holds the entry in the caller's own process, for the whole call" do
      script = accepted(@faulty)
      parent = self()

      run =
        Task.async(fn ->
          send(parent, {:running, self()})
          Runner.run(script, "naps", %{})
        end)

      assert_receive {:running, caller}
      assert wait_until(fn -> Runner.in_flight?(script.name) end, 100)
      assert {caller, :run} in Registry.lookup(YmerNode.Scripts.Runs, script.name)
      assert {:ok, %{"slept" => true}} = Task.await(run)
    end

    @tag doc: """
         The task's own entry goes before the run answers, not when the registry
         notices the task is gone. A caller that runs a script and writes it on
         the next line was otherwise refused `run_in_flight` about half the time
         for a run that had already answered — 723 of 2000 sequential runs still
         saw the entry, before the task released it itself. Fifty runs here,
         because one would pass by luck.
         """
    test "is not in flight the moment run/3 answers" do
      script = accepted(@greeter)

      for _ <- 1..50 do
        assert {:ok, %{"greeting" => "hello x"}} = Runner.run(script, "greet", %{"name" => "x"})
        refute Runner.in_flight?(script.name)
      end
    end

    @tag doc: """
         A caller can die mid-run — a client cancelling, an rpc interrupted — and
         the task it started is not linked to it. Without an entry of the task's
         own the run would vanish from `in_flight?/1` the moment the caller died,
         while still executing, and a write could purge the tree under it;
         without a kill of the task's own it would run past every deadline with
         nobody waiting. Both halves are asserted after the caller is killed. The
         second wait outlasts the action's deadline by the backstop's grace,
         which is why it is longer than the 50 ms the action asked for.
         """
    test "a run whose caller dies stays in flight and dies at its own deadline" do
      mailbox = :"runner_orphan_#{System.unique_integer([:positive])}"
      Process.register(self(), mailbox)

      script =
        accepted("""
          @impl true
          def description, do: "sleeps for ages"

          @impl true
          def actions do
            %{stuck: %{description: "sleeps", properties: %{}, write: false, timeout: 50}}
          end

          @impl true
          def declarations, do: %{hosts: [], url_action: nil, secrets: []}

          @impl true
          def run(:stuck, _args, _context) do
            send(#{inspect(mailbox)}, {:executing, self()})
            Process.sleep(60_000)
            {:ok, %{}}
          end
        """)

      caller = spawn(fn -> Runner.run(script, "stuck", %{}) end)
      assert_receive {:executing, task}, 1_000

      Process.exit(caller, :kill)
      refute Process.alive?(caller)

      registry = YmerNode.Scripts.Runs
      assert wait_until(fn -> Registry.lookup(registry, script.name) == [{task, :task}] end, 100)
      assert Runner.in_flight?(script.name)
      assert Process.alive?(task)

      assert wait_until(fn -> not Process.alive?(task) end, 300)
      assert wait_until(fn -> not Runner.in_flight?(script.name) end, 100)
    end
  end

  describe "check/3" do
    test "answers the action's schema for a call the run would serve, running nothing" do
      script = accepted(@greeter)

      assert {:ok, %{required: ["name"]}} = Runner.check(script, "greet", %{"name" => "x"})
      refute Runner.in_flight?(script.name)
    end

    test "refuses what the run would refuse, with the run's own reasons" do
      script = accepted(@greeter)
      stale = %{script | accepted_hash: Script.hash("some other code")}

      assert {:error, {:not_accepted, _detail}} = Runner.check(stale, "greet", %{"name" => "x"})
      assert {:error, {:unknown_action, message}} = Runner.check(script, "fetch", %{})
      assert message =~ "has no action fetch"
      assert {:error, {:invalid_args, missing}} = Runner.check(script, "greet", %{})
      assert missing =~ "property 'name' is required"
    end

    test "refuses a script this node has not compiled" do
      code = "defmodule Script.NeverChecked do\nend\n"
      hash = Script.hash(code)

      script = %Script{
        name: "never_checked_#{System.unique_integer([:positive])}",
        code: code,
        code_hash: hash,
        accepted_hash: hash
      }

      assert {:error, {:not_loaded, message}} = Runner.check(script, "anything", %{})
      assert message =~ "has not been compiled since this node started"
    end
  end

  defp files_dir do
    :ymer_node
    |> Application.get_env(YmerNode.Script.Context)
    |> Keyword.fetch!(:files_dir)
  end

  defp accepted(body) do
    %{code: code, name: name, module: module} = fixture(body: body)

    assert {:ok, _compiled} = Loader.load(code)
    on_exit(fn -> Loader.unload(name, module) end)

    %Script{
      name: name,
      code: code,
      code_hash: Script.hash(code),
      accepted_hash: Script.hash(code),
      origin: "authored",
      contract: 1
    }
  end

  defp wait_until(fun, attempts) do
    cond do
      fun.() ->
        true

      attempts == 0 ->
        false

      true ->
        Process.sleep(10)
        wait_until(fun, attempts - 1)
    end
  end
end
