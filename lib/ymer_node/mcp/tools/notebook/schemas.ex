defmodule YmerNode.Mcp.Tools.Notebook.Schemas do
  @moduledoc """
  Schema definitions for the `notebook` tool's actions. The `:notes`/`:examples` are the
  agent's primary documentation for sqlite-vec usage and the INTEGER-PRIMARY-KEY
  join discipline — they surface via the `help` tool.
  """

  @sql %{"type" => "string", "description" => "A single SQL statement."}
  @table %{"type" => "string", "description" => "Table name to describe."}
  @backup_id %{"type" => "string", "description" => "A backup id, exactly as returned by list."}

  @vec_notes """
  sqlite-vec is loaded. Vector storage uses `CREATE VIRTUAL TABLE name USING \
  vec0(embedding float[N])`. ALWAYS keep a companion regular table for document \
  content and join the two by rowid — and declare that companion table's key as \
  `id INTEGER PRIMARY KEY` (this aliases rowid so it survives VACUUM; a TEXT \
  PRIMARY KEY does NOT, and KNN joins will silently corrupt). Store the business \
  key (e.g. a Jira key) as a separate UNIQUE TEXT column. Insert the embedding at \
  the same integer id. There is no cascade, so delete from both tables together. \
  Describe BOTH tables in `_meta` — a `table:name` row AND a `table:vec_name` row — \
  because `tables`/`schema` report `description: null` for any table without one, and \
  the vec0 virtual table is the one most often left undescribed. \
  Embeddings are produced by Ollama before calling this tool; pass the float array \
  as a JSON string. KNN search MUST carry a LIMIT, and the MATCH+LIMIT MUST run in \
  its OWN subquery/CTE that you then join to the companion table by rowid — \
  sqlite-vec (v0.1.6) will NOT push a LIMIT through a direct \
  `vec_name JOIN name … ORDER BY distance LIMIT k` and errors "A LIMIT or 'k = ?' \
  constraint is required on vec0 knn queries". Correct shape: `WITH knn AS (SELECT \
  rowid, distance FROM vec_name WHERE embedding MATCH '[…]' ORDER BY distance LIMIT \
  k) SELECT n.*, knn.distance FROM knn JOIN name n ON n.id = knn.rowid ORDER BY \
  knn.distance`.
  """

  @schemas %{
    execute: %{
      description:
        "Run a DDL/DML statement (CREATE/ALTER/DROP/INSERT/UPDATE/DELETE). Returns affected_rows.",
      properties: %{"sql" => @sql},
      required: ["sql"],
      defaults: %{},
      notes:
        "The write/schema surface. ATTACH/DETACH and VACUUM INTO are rejected. " <>
          @vec_notes,
      examples: [
        %{
          data: %{
            sql:
              "CREATE TABLE confluence_pages (id INTEGER PRIMARY KEY, page_key TEXT UNIQUE, title TEXT, body TEXT)"
          }
        },
        %{
          data: %{
            sql: "CREATE VIRTUAL TABLE vec_confluence_pages USING vec0(embedding float[768])"
          }
        },
        %{
          data: %{
            sql:
              "INSERT OR REPLACE INTO _meta (target, description) VALUES ('table:confluence_pages', 'Indexed Confluence pages for semantic search')"
          }
        },
        %{
          data: %{
            sql:
              "INSERT OR REPLACE INTO _meta (target, description) VALUES ('table:vec_confluence_pages', '768-d embeddings for confluence_pages; KNN-joined by rowid')"
          }
        }
      ],
      related: ["query", "tables", "schema"]
    },
    query: %{
      description:
        "Run a read-only SELECT/WITH/EXPLAIN. Returns columns + rows. Use LIMIT/OFFSET for paging.",
      properties: %{"sql" => @sql},
      required: ["sql"],
      defaults: %{},
      notes:
        "Read-only: the statement runs in a transaction that is always rolled back, " <>
          "so it cannot persist writes. EXPLAIN/EXPLAIN QUERY PLAN are allowed; PRAGMA " <>
          "is not — use the schema/tables actions for introspection and execute for " <>
          "writes. " <> @vec_notes,
      examples: [
        %{
          data: %{
            sql:
              "WITH knn AS (SELECT rowid, distance FROM vec_confluence_pages WHERE embedding MATCH '[0.1, -0.2, ...]' ORDER BY distance LIMIT 10) SELECT p.page_key, p.title, knn.distance FROM knn JOIN confluence_pages p ON p.id = knn.rowid ORDER BY knn.distance"
          }
        }
      ],
      related: ["execute", "schema"]
    },
    tables: %{
      description:
        "List user tables with row counts and _meta descriptions (vec0 tables flagged virtual).",
      properties: %{},
      required: [],
      defaults: %{},
      related: ["schema"]
    },
    schema: %{
      description:
        "Show one table's columns, indexes and _meta descriptions (or vec0 vector columns).",
      properties: %{"table" => @table},
      required: ["table"],
      defaults: %{},
      related: ["tables"]
    },
    create: %{
      description:
        "Save a backup of the notebook, so you can roll back to it later. Returns its id.",
      properties: %{},
      required: [],
      defaults: %{},
      notes:
        "One backup is one file, addressed by one id. Older backups beyond the retention " <>
          "limit are removed automatically after a successful capture. Only one backup or " <>
          "restore runs at a time — if one is already running you are told to retry.",
      related: ["list", "restore"]
    },
    list: %{
      description:
        "List saved backups, newest first — each has an id, when it was taken, and its size.",
      properties: %{},
      required: [],
      defaults: %{},
      notes: "Use a returned id with restore.",
      related: ["create", "restore"]
    },
    restore: %{
      description:
        "Roll the notebook back to a saved backup (by id). Read the notes before calling.",
      properties: %{"id" => @backup_id},
      required: ["id"],
      defaults: %{},
      notes:
        "This overwrites everything currently in the notebook. A fresh backup of the " <>
          "current state is taken automatically first and its id is returned as " <>
          "safety_backup, so the roll-back can itself be rolled back — but it counts " <>
          "against the retention limit like any other, so undo soon rather than later. " <>
          "Get ids from list.",
      related: ["create", "list"]
    }
  }

  def all, do: @schemas
end
