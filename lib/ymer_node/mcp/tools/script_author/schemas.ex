defmodule YmerNode.Mcp.Tools.ScriptAuthor.Schemas do
  @moduledoc """
  Action schemas for the `script_author` tool. The `notes` surface through the
  `help` tool and are the worker-facing contract of each call — what it does,
  what it refuses, what its flags mean. The script contract itself is not
  written here: `scripts guide` renders it from `YmerNode.Script`'s own docs,
  and the notes of `check` and `create` point there.
  """

  @script %{
    "type" => "string",
    "description" =>
      "A script's or library's name — derived from its module, so `Script.Hex` " <>
        ~s|is "hex" and `Library.Crosskey` is "crosskey". | <>
        "`scripts list` names them all.",
    "minLength" => 1,
    "examples" => ["hex", "req_test"]
  }

  @code %{
    "type" => "string",
    "description" =>
      "The whole Elixir module, as code. One top-level `defmodule Script.<Name>` " <>
        "that does `use YmerNode.Script` and implements description/0, version/0, " <>
        "actions/0, declarations/0 and run/3 — or, for a library, one " <>
        "`defmodule Library.<Name>` that does `use YmerNode.Library` and " <>
        "implements description/0 and version/0.",
    "minLength" => 1
  }

  @acceptance """
  Storing code accepts it, at exactly those bytes. Acceptance refuses: a \
  `url_action` `actions/0` does not declare; a `url_action` whose schema has no \
  `url` property; a name that is a built-in reference source (web, file, \
  other); a host another accepted script already claims; a web fallback \
  (`web_fallback: true`) while another accepted script is the web fallback; a \
  throttle another accepted script declares with other parameters; a \
  `Library.` module the code names and `libraries` does not declare; a \
  declared library this node does not hold, holds Broken, or holds at a \
  version outside the requirement; and, where a write lands new code, a \
  version/0 the stored row already holds with other code, or a library version \
  outside what a declaring script requires.\
  """

  @schemas %{
    check: %{
      description: "Compile code and report what it would become — writes nothing",
      properties: %{"code" => @code},
      required: ["code"],
      defaults: %{},
      notes:
        "Read `scripts guide` first — the contract a script implements and the " <>
          "functions it is handed, rendered from the node's own docs. Then the " <>
          "call to make before `create`: the derived name, the contract, the " <>
          "description, every action's schema, the declarations, and any compile " <>
          "warnings. Nothing is written and nothing is accepted. Every refusal is " <>
          "the one `create` would have given. `existing` says whether this node " <>
          "already holds a script of the derived name: true means `create` will be " <>
          "refused and `update` is the call to make. Refused while a run of that " <>
          "name is in flight, because checking compiles the candidate and that " <>
          "would displace the running one.",
      related: ["create", "update"]
    },
    create: %{
      description: "Create a script from code, accepted at exactly those bytes",
      properties: %{"code" => @code},
      required: ["code"],
      defaults: %{},
      notes:
        "The name is derived, never given, so there is no name argument. A name " <>
          "that already exists is refused, pointing at `update` — two scripts with " <>
          "one name would be different code, and answering the existing one would " <>
          "hide a write that did nothing. The contract the code must satisfy is " <>
          "`scripts guide`'s; `check` first. " <> @acceptance,
      related: ["check", "update"]
    },
    update: %{
      description: "Replace one script's code, whole",
      properties: %{"script" => @script, "code" => @code},
      required: ["script", "code"],
      defaults: %{},
      notes:
        "Whole replacement, not a patch, and there is no version history — the " <>
          "previous code is gone, and a version/0 names the code it stands for: " <>
          "new code needs one other than the stored one, a lower one to roll " <>
          "back, and a library's must stay inside every requirement of the " <>
          "scripts declaring it. The new code must derive to the SAME name; " <>
          "renaming is `remove` then `create`. Refused while a run of that script " <>
          "is in flight, because landing it would kill the run mid-way; retry when " <>
          "it ends. " <> @acceptance,
      related: ["check", "remove"]
    },
    accept: %{
      description: "Mark a script's stored code accepted, as of now",
      properties: %{"script" => @script},
      required: ["script"],
      defaults: %{},
      notes:
        "Rarely needed today: `create` and `update` already accept what they " <>
          "store, so the only unaccepted script is one whose code arrived some " <>
          "other way. `scripts run` refuses anything unaccepted. " <> @acceptance,
      related: ["update", "check"]
    },
    remove: %{
      description: "Permanently delete a script and unload it",
      properties: %{"script" => @script},
      required: ["script"],
      defaults: %{},
      notes:
        "Hard delete, and the code is not kept anywhere — take a copy first if " <>
          "it is not in a repository. Any reference whose source this script " <>
          "declared falls back to its built-in classification the same moment. " <>
          "Its schedules are removed with it, and the answer names them. Refused " <>
          "while a run of that script is in flight. A library any script declares " <>
          "is refused, naming those scripts.",
      related: ["update", "create"]
    }
  }

  def all, do: @schemas
end
