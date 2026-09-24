defmodule Script.Throttled do
  use YmerNode.Script

  alias YmerNode.Script.Context

  @impl true
  def description, do: "reads one value through a throttle, signing in with a secret"

  @impl true
  def actions, do: %{get: %{description: "reads the value", properties: %{}, write: false}}

  @impl true
  def declarations do
    %{
      hosts: [],
      url_action: nil,
      secrets: ["PROBE_PASSWORD"],
      throttles: %{"probe" => %{rate: 60, burst: 2}}
    }
  end

  @impl true
  def run(:get, _args, context) do
    with {:ok, password} <- Context.secret(context, "PROBE_PASSWORD"),
         {:ok, %{status: 200, body: body}} <-
           Context.request(context,
             url: "https://probe.test/value",
             auth: {:basic, "probe:" <> password},
             throttle: "probe"
           ) do
      {:ok, body}
    end
  end
end
