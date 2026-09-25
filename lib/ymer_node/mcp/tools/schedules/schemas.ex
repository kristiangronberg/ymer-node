defmodule YmerNode.Mcp.Tools.Schedules.Schemas do
  @moduledoc """
  Action schemas for the `schedules` tool. The `notes` surface through the `help`
  tool and are the worker-facing contract: what a cron expression and a lifetime
  look like, what `add` refuses rather than leaving to a firing, and what a
  firing skips.
  """

  @name %{
    "type" => "string",
    "description" =>
      "The schedule's name, unique on this node — lowercase letters, digits, - and " <>
        "_, starting with a letter or digit. Every other action addresses it by this.",
    "minLength" => 1,
    "examples" => ["morning-report", "hourly-ui"]
  }

  @script %{
    "type" => "string",
    "description" => "The script to run, by name — `scripts list` names them.",
    "minLength" => 1,
    "examples" => ["hex"]
  }

  @action %{
    "type" => "string",
    "description" =>
      "Which of the script's actions to run. `scripts describe` lists them with " <>
        "their arguments and their write marks.",
    "minLength" => 1
  }

  @args %{
    "type" => "object",
    "description" =>
      "The arguments every firing's run gets, checked against the action's schema " <>
        "now and again at each firing. Stored on the schedule and shown by every " <>
        "list from then on, so never a secret: a script that needs one declares it " <>
        "and reads it at run time.",
    "additionalProperties" => true
  }

  @cron_expression %{
    "type" => "string",
    "description" =>
      "When it fires, read in the node's time zone: five fields — minute, hour, " <>
        "day of month, month, day of week — or one of @hourly, @daily, @midnight, " <>
        "@weekly, @monthly, @yearly, @annually.",
    "minLength" => 1,
    "examples" => ["0 7 * * MON-FRI", "*/15 * * * *", "@daily"]
  }

  @lifetime %{
    "type" => "string",
    "description" =>
      "How long it keeps firing: an ISO-8601 span from now (P30D, PT12H, P2W), or " <>
        "a date-time — with an offset it means exactly that, without one it is read " <>
        "in the node's time zone. Left out it is 90 days, and longer is cut to 90.",
    "minLength" => 1,
    "examples" => ["P30D", "2026-12-24T18:00:00"]
  }

  @schemas %{
    add: %{
      description: "Add a schedule",
      properties: %{
        "name" => @name,
        "script" => @script,
        "action" => @action,
        "args" => @args,
        "cron_expression" => @cron_expression,
        "lifetime" => @lifetime
      },
      required: ["name", "script", "action", "cron_expression"],
      defaults: %{"args" => %{}},
      notes:
        "Refused now, rather than at a firing nobody watches: a taken or malformed " <>
          "name; a cron expression that is not five fields or a nickname — @reboot, " <>
          "a sixth year field and a short form are refused; a lifetime that is " <>
          "malformed, already past, or a bare date with no time; a script that is " <>
          "unknown or not accepted; an action it does not serve; args its schema " <>
          "rejects. The answer carries the end and the next firing, in the node's " <>
          "time zone with its offset. A firing runs through the runner `scripts run` " <>
          "uses, under the same deadline. A firing the node was not up for is " <>
          "skipped, never caught up, and so is one while this schedule's previous " <>
          "run is still in flight. The args are stored and listed as given — a key " <>
          "the action does not declare is let through, not refused — so a secret " <>
          "never goes in them.",
      related: ["list", "update", "remove"]
    },
    list: %{
      description: "List every schedule on this node",
      properties: %{},
      required: [],
      defaults: %{},
      notes:
        "Every schedule by name: its script, action, args and cron expression; " <>
          "active or expired; its next firing and its end; and its last run — when " <>
          "it fired, ok, refused, error or timeout, the runner's message, how long " <>
          "it took. refused means the run never started: fix the schedule, or " <>
          "accept the script. error means the script ran and failed. A skipped " <>
          "firing leaves no trace.",
      related: ["add", "update", "remove"]
    },
    update: %{
      description: "Change a schedule's cron expression, args or lifetime",
      properties: %{
        "name" => @name,
        "cron_expression" => @cron_expression,
        "args" => @args,
        "lifetime" => @lifetime
      },
      required: ["name"],
      defaults: %{},
      notes:
        "Any of the three, each checked as at add; the last run is kept. A " <>
          "lifetime given here is read from now, and is how a schedule is renewed, " <>
          "expired or not; without one the end stays where it is. The script and " <>
          "the action are fixed — another is another schedule: remove this one and " <>
          "add it.",
      related: ["list", "add"]
    },
    remove: %{
      description: "Remove a schedule",
      properties: %{"name" => @name},
      required: ["name"],
      defaults: %{},
      notes:
        "Deletes the schedule; a run already in flight finishes. Removing a script " <>
          "removes its schedules too.",
      related: ["list", "add"]
    }
  }

  def all, do: @schemas
end
