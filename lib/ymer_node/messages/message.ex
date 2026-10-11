defmodule YmerNode.Messages.Message do
  @moduledoc """
  What one session posts to a thread for others to read: its body, the handle
  that sent it, the thread, a node-assigned increasing id and the node's time.
  Held in memory by the node, never persisted.

  The bare word *message* in this repository is this sense. The others stay
  qualified: a JSON-RPC message, an error message, a process message.

  `at` is UTC, truncated to the second; `YmerNode.Messages` renders it in the
  node's time zone on every answer. `id` orders every message the process has
  held, across all threads, which is what lets a read's cursor be one id.
  """

  @type t :: %__MODULE__{}

  @enforce_keys [:id, :thread, :handle, :at, :body]
  defstruct @enforce_keys
end
