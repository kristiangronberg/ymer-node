defmodule YmerNode.CarryingPages do
  @moduledoc """
  Test support standing in for a carrying application's pages plug. It is a
  module plug that declares no `@behaviour Plug`, as a plug need not: `init/1`
  sends the calling process `{:pages_init, options}`, and `call/2` sends it
  `{:pages_conn, conn}` with the conn it was handed and answers `pages`.

  `YmerNode.FailingPages`, beside it, is a pages plug whose `init/1` raises, and
  `YmerNode.InitOnlyPages` and `YmerNode.CallOnlyPages` are half plugs, each
  exporting one of the two functions.
  """
  import Plug.Conn

  def init(options) do
    send(self(), {:pages_init, options})
    :carrying_pages
  end

  def call(conn, :carrying_pages) do
    send(self(), {:pages_conn, conn})
    send_resp(conn, 200, "pages")
  end
end

defmodule YmerNode.FailingPages do
  @moduledoc """
  Test support: a pages plug whose `init/1` raises, as a carrying application's
  plug might when it cannot start.
  """
  def init(_options), do: raise("carrying pages refused to start")

  def call(conn, _options), do: conn
end

defmodule YmerNode.InitOnlyPages do
  @moduledoc """
  Test support: a half plug that exports `init/1` and no `call/2`.
  """
  def init(options), do: options
end

defmodule YmerNode.CallOnlyPages do
  @moduledoc """
  Test support: a half plug that exports `call/2` and no `init/1`.
  """
  def call(conn, _options), do: conn
end
