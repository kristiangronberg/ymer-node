import Config

# The node has exactly one mode: it serves. So the port carries a real default
# here rather than existing only in the container's environment — a `docker run`
# with no PORT set must still boot. `config/runtime.exs` overrides it when PORT
# is present.
#
# The bind address is deliberately absent, so a release falls to the loopback
# default and a bare `bin/ymer_node start` on a host exposes nothing to that
# host's networks. Only the node's own image widens the bind, through the marker
# file `config/runtime.exs` checks at boot — see `YmerNode.Mcp`'s security-model
# section for why the widening lives in the image rather than here.
config :ymer_node, YmerNode.Mcp, port: 8012

# Secrets live beside the databases inside the volume the install keeps, so
# they survive a deploy the way the store does. Named as a file, not a
# directory: unlike the databases there is exactly one of them.
# `config/runtime.exs` moves it when SECRETS_PATH says so.
config :ymer_node, YmerNode.Secrets, path: "/data/secrets.env"

# Pinned, because unpinned a release logs at `:debug`, and Ecto's query lines
# then carry every script's whole code into the log — and into the terminal of
# an operator's verb, where `scripts export` must print the code and nothing
# else (`YmerNode.Scripts.CLI`'s "Talking back").
config :logger, level: :info
