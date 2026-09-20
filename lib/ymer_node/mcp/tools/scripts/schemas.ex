defmodule YmerNode.Mcp.Tools.Scripts.Schemas do
  @moduledoc """
  Action schemas for the `scripts` tool. The `notes` surface through the `help`
  tool and are the worker-facing contract: what a run costs, what acceptance
  means, and why `describe` is the call to make before `run`.

  `info`'s `name` carries an `enum`, where the references tool's `source`
  deliberately carries none: that vocabulary is runtime data, this one is the
  curated list `YmerNode.Scripts.PackageDocs` compiles, so the schema reads it
  from there and cannot drift from what the action accepts.
  """
  alias YmerNode.Scripts.PackageDocs

  @script %{
    "type" => "string",
    "description" =>
      "The script's name — derived from its module, so `Script.Hex` is \"hex\" " <>
        "and `Script.ReqTest` is \"req_test\". `list` names them all.",
    "minLength" => 1,
    "examples" => ["hex", "req_test"]
  }

  @action %{
    "type" => "string",
    "description" =>
      "Which of the script's actions to run. `describe` lists them with their " <>
        "arguments and their write marks.",
    "minLength" => 1
  }

  @args %{
    "type" => "object",
    "description" =>
      "Arguments for the action, matching the properties `describe` reports. " <>
        "Validated against that schema before the run starts.",
    "additionalProperties" => true
  }

  @code %{
    "type" => "boolean",
    "description" =>
      "Include the script's code — the whole of what sharing it needs. Off by " <>
        "default: it can be long."
  }

  @name %{
    "type" => "string",
    "description" =>
      "A promised package by its hex name — the first word of its row's Use cell " <>
        "in the guide's table, and `req` for Req. Not `json` (Elixir's own) and not " <>
        "the context, which the guide itself renders.",
    "enum" => PackageDocs.names(),
    "examples" => ["sweet_xml", "elixlsx"]
  }

  @schemas %{
    list: %{
      description: "List every script this node holds",
      properties: %{},
      required: [],
      defaults: %{},
      notes:
        "Slim: name, description, origin, action names, and whether the script " <>
          "is accepted and compiled. A script that is not BOTH cannot run, and " <>
          "carries the reason why — it is listed rather than hidden, because the " <>
          "fix is to look at it. Call `describe` for an action's arguments.",
      related: ["describe", "run"]
    },
    describe: %{
      description: "One script in full: its actions, their arguments, their write marks",
      properties: %{"script" => @script, "code" => @code},
      required: ["script"],
      defaults: %{"code" => false},
      notes:
        "The call to make before `run`: it reports each action's properties and " <>
          "required list, which the run is validated against, plus the `write` " <>
          "mark saying whether the action changes anything outside this node. " <>
          "Read before you write. `declarations` names the hosts this script " <>
          "claims for references, the secrets it resolves and the throttles it " <>
          "names, with their parameters; the secrets' VALUES " <>
          "never appear here or anywhere else. With `code: true` the answer " <>
          "carries the code as well, and a hint says how to share it.",
      related: ["run", "list"]
    },
    guide: %{
      description: "The script contract and the batteries, for writing a script",
      properties: %{},
      required: [],
      defaults: %{},
      notes:
        "The call to make before writing a script, read whole once: the docs of " <>
          "`YmerNode.Script` — the four callbacks, the action shape, the loop, " <>
          "what a script may call, secrets, sharing — and of " <>
          "`YmerNode.Script.Context`, the functions a script is handed. Then " <>
          "`script_author check` the code before `create`. It is the same text " <>
          "the published docs carry, rendered here from this build's own docs and " <>
          "followed by the applications this node carries; a build that stripped " <>
          "the docs is refused whole rather than answered in part.",
      related: ["describe", "list", "info"]
    },
    info: %{
      description: "A promised package's own documentation, from this release",
      properties: %{"name" => @name},
      required: ["name"],
      defaults: %{},
      notes:
        "The read before the first script that uses one of the guide's rows: the " <>
          "package's moduledocs, types and functions, rendered from this release's " <>
          "own docs at the version it carries — the same text hexdocs shows for " <>
          "that version, so what you read is what the run will call. Long, and " <>
          "whole: `mdex` is about 33 KB. What the node promises of a package, and " <>
          "what a row cannot say — the facts its docs do not carry — are in " <>
          "`guide`, which is where the names come from.",
      related: ["guide"]
    },
    run: %{
      description: "Run one of a script's actions",
      properties: %{"script" => @script, "action" => @action, "args" => @args},
      required: ["script", "action"],
      defaults: %{"args" => %{}},
      notes:
        "Runs only while the script is accepted at exactly the code stored — an " <>
          "unaccepted script is refused, and the fix is `accept` via " <>
          "`script_author` or the CLI. The run is isolated and bounded: 30 " <>
          "seconds unless the action asks for more, never past 5 minutes, and a " <>
          "run past its deadline is killed. A killed run's effects OUTSIDE this " <>
          "node may already have landed, which is why `describe`'s write mark is " <>
          "worth reading first. A script reaches the network: this action is the " <>
          "one open-world thing the node does.",
      related: ["describe", "list"]
    }
  }

  def all, do: @schemas
end
