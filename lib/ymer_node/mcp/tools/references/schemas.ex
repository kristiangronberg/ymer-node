defmodule YmerNode.Mcp.Tools.References.Schemas do
  @moduledoc """
  Action schemas for the `references` tool. The `notes` surface through the
  `help` tool and are the worker-facing contract documentation — the mode
  contract, the duplicate rule, and the membrane.
  """

  @id %{
    "type" => ["integer", "string"],
    "description" => "Reference id (an integer, or its string form).",
    "examples" => [1, "1"]
  }

  @title %{
    "type" => "string",
    "description" => "Short name for the target (2–255 characters).",
    "minLength" => 2,
    "maxLength" => 255
  }

  @description %{
    "type" => "string",
    "description" =>
      "Local routing knowledge: what lives there and when to look. Never a copy " <>
        "of the target's content — references are pointers, not content."
  }

  @uri %{
    "type" => "string",
    "description" =>
      "Where the target lives: a URL, a file path, or an app link. The uri itself " <>
        "is the deep link — paste it exactly as it is.",
    "minLength" => 1,
    "examples" => [
      "https://elixir-lang.org/getting-started/introduction.html",
      "/Users/you/notes/architecture.md",
      "x-devonthink-item://1B0C482D-6725-4E5F-9E36-2C89E1F6A7B0"
    ]
  }

  @fragment %{
    "type" => "string",
    "description" =>
      "Optional directions within the target: a section heading, an attachment " <>
        "name, or coordinates (\"the retry table under Configuration\") when the " <>
        "target has no deep URL of its own."
  }

  @tags %{
    "type" => "array",
    "items" => %{"type" => "string"},
    "description" =>
      "Free-text labels — your own vocabulary, and the only thing binding a " <>
        "reference to anything else you keep."
  }

  @filter_tags Map.put(
                 @tags,
                 "description",
                 "References must carry ALL of these tags (AND — narrowing)."
               )

  # No "enum" here, deliberately. The vocabulary is runtime data — the three
  # built-ins plus every accepted script's name — so a compile-time list would
  # start lying the first time a script was accepted. The invalid-source error
  # names the current vocabulary instead.
  @source %{
    "type" => "string",
    "description" =>
      "Derived uri classification: web (any http/https), file (file:// or " <>
        "path-like), other (a non-http scheme, such as an app deep link), or the " <>
        "name of any accepted script that claims the uri's host. Derived from the " <>
        "uri, never typed — every result carries its source."
  }

  @limit %{
    "type" => "integer",
    "description" => "Max results (default 50, max 100).",
    "minimum" => 1,
    "maximum" => 100
  }

  @schemas %{
    find: %{
      description: "Find references by tags, source, and/or a ranked free-text query",
      properties: %{
        "query" => %{
          "type" => "string",
          "description" => "Free text to rank by (topics, names, identifiers).",
          "minLength" => 1
        },
        "tags" => @filter_tags,
        "source" => @source,
        "limit" => @limit
      },
      required: [],
      defaults: %{},
      notes:
        "At least one of query/tags/source is required — use `list` to browse " <>
          "everything. `mode` names the ranking that ran: 'keyword' (distinct-term " <>
          "match over ALL text fields — title, description, fragment, uri, tags — so " <>
          "an identifier matches a reference whose uri carries it) or 'filter' (no " <>
          "query given; filters only, newest first). Every result embeds its derived " <>
          "`source` and, where one is derivable, a fetch `recipe` (tool + action + " <>
          "params): call that yourself to get the live content — this tool never " <>
          "fetches.",
      related: ["get", "list", "add"]
    },
    add: %{
      description: "Add a reference: title + uri (plus description, fragment, tags)",
      properties: %{
        "title" => @title,
        "description" => @description,
        "uri" => @uri,
        "fragment" => @fragment,
        "tags" => @tags
      },
      required: ["title", "uri"],
      defaults: %{},
      notes:
        "One reference per (uri, fragment): adding an exact duplicate creates " <>
          "nothing — the response points at the reference that already exists, so " <>
          "update or tag that one instead. Same uri with different fragments is " <>
          "legitimate (two sections of one page). The description is routing " <>
          "knowledge — what lives there, when to look — and never a copy of the " <>
          "target's content. Until registry sync lands, a reference added here " <>
          "lives only on this machine.",
      related: ["update", "find"]
    },
    get: %{
      description: "Retrieve a reference by id",
      properties: %{"id" => @id},
      required: ["id"],
      defaults: %{},
      related: ["list", "update"]
    },
    update: %{
      description: "Update a reference's fields (title, description, uri, fragment, tags)",
      properties: %{
        "id" => @id,
        "title" => @title,
        "description" => @description,
        "uri" => @uri,
        "fragment" => @fragment,
        "tags" => @tags
      },
      required: ["id"],
      defaults: %{},
      notes:
        "Only the fields you provide are changed. Tags ride update — there is no " <>
          "separate tag action — so pass the FULL tags array: it replaces, it does " <>
          "not merge. Moving uri/fragment onto another reference's exact pair fails " <>
          "the uniqueness rule.",
      related: ["get", "remove"]
    },
    remove: %{
      description: "Permanently delete a reference",
      properties: %{"id" => @id},
      required: ["id"],
      defaults: %{},
      notes:
        "Hard delete — a reference is a pointer, not content, and nothing points " <>
          "at it. Prefer update when the target has merely moved.",
      related: ["find", "list"]
    },
    list: %{
      description: "List the whole registry",
      properties: %{},
      required: [],
      defaults: %{},
      notes:
        "Browse-and-scan in title order, no filters — use find to narrow. Every " <>
          "reference carries its derived source and, where one is derivable, its " <>
          "fetch recipe.",
      related: ["find", "get"]
    }
  }

  def all, do: @schemas
end
