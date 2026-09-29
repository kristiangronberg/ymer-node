defmodule YmerNode.Mcp.Tools.References.Schemas do
  @moduledoc """
  Action schemas for the `references` tool. The `notes` surface through the
  `help` tool and are the worker-facing contract documentation — the mode
  contract, the duplicate rule, the read window, and the membrane
  (`YmerNode.References` § The membrane).
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
      "Local routing knowledge: what lives there and when to look. Never the " <>
        "target's content — that lives in the cache, and read serves it."
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

  @offset %{
    "type" => "integer",
    "description" => "The line the window starts at, from 1 (default 1).",
    "minimum" => 1
  }

  @lines %{
    "type" => "integer",
    "description" =>
      "How many lines the window holds at most (default: as many as fit the byte budget).",
    "minimum" => 1
  }

  @column %{
    "type" => "integer",
    "description" =>
      "The character of the first line to go on from, from 1 (default 1) — the " <>
        "column a cut line's `next` names.",
    "minimum" => 1
  }

  @cadence_minutes %{
    "type" => "integer",
    "description" => "How often the watch refreshes the entry, in minutes.",
    "enum" => [5, 15, 30, 60]
  }

  @lifetime_hours %{
    "type" => "integer",
    "description" => "How long the watch lives, in hours (1–12).",
    "minimum" => 1,
    "maximum" => 12
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
          "params): read serves the target's content from the cache, fetching it " <>
          "through that recipe on a miss.",
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
          "knowledge — what lives there, when to look — and never the target's " <>
          "content, which the cache keeps and read serves. Until registry sync " <>
          "lands, a reference added here lives only on this machine.",
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
          "the uniqueness rule, and moving them at all drops the cache entry, so " <>
          "the next read fetches the new target.",
      related: ["get", "remove"]
    },
    remove: %{
      description: "Permanently delete a reference",
      properties: %{"id" => @id},
      required: ["id"],
      defaults: %{},
      notes:
        "Hard delete — a reference is a pointer, and its cache entry and its " <>
          "watch go with it. Prefer update when the target has merely moved.",
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
    },
    read: %{
      description: "Read a reference's content from the cache, fetching it once when absent",
      properties: %{"id" => @id, "offset" => @offset, "limit" => @lines, "column" => @column},
      required: ["id"],
      defaults: %{},
      notes:
        "Text comes back by line window — offset and limit count lines, and a " <>
          "window never passes 24 000 bytes; next names where the following window " <>
          "starts, with a column when a single long line was cut. An image comes " <>
          "back as image content. Any other format is described — its format, " <>
          "size and path in the cache directory — not served. Every answer " <>
          "carries fetched_at (when the content last changed, as far as the node " <>
          "knows) and checked_at (when the script was last asked): the cache is " <>
          "never ahead of the target and may be behind it. A reference " <>
          "no script fetches is refused, and its uri is the pointer to follow.",
      related: ["refresh", "watch", "get"]
    },
    refresh: %{
      description: "Ask the reference's script now whether the target changed, and keep it",
      properties: %{"id" => @id},
      required: ["id"],
      defaults: %{},
      notes:
        "Runs the recipe with what the script answered last time, so a script with " <>
          "a change check answers unchanged cheaply; outcome says fetched or " <>
          "unchanged. A refusal keeps the entry that was there.",
      related: ["read", "watch"]
    },
    watch: %{
      description: "Keep a reference's cached content current for a while",
      properties: %{
        "id" => @id,
        "cadence_minutes" => @cadence_minutes,
        "lifetime_hours" => @lifetime_hours
      },
      required: ["id", "cadence_minutes", "lifetime_hours"],
      defaults: %{},
      notes:
        "Starts a watch — a schedule this reference owns, named reference-<id> — " <>
          "that refreshes the entry every cadence_minutes (5, 15, 30 or 60) for " <>
          "lifetime_hours (1–12), and refreshes once now. Watching a watched " <>
          "reference replaces its cadence and lifetime. schedules list shows it " <>
          "and schedules remove stops it, as unwatch does. Each firing runs " <>
          "whichever script fetches the reference then.",
      related: ["unwatch", "read"]
    },
    unwatch: %{
      description: "Stop a reference's watch",
      properties: %{"id" => @id},
      required: ["id"],
      defaults: %{},
      related: ["watch"]
    }
  }

  def all, do: @schemas
end
