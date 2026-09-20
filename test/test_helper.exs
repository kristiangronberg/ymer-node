# capture_log is GLOBAL, and it is the silencing mechanism for the error lines
# the suite expects: restore failures logged server-side, a lock's contained
# exits, a pool that cannot open its store. Per-case :capture_log tags in the
# test files are documentation of expected noise, not what silences it.
ExUnit.start(capture_log: true)

if YmerNode.Notebook.Repo.running?(),
  do: Ecto.Adapters.SQL.Sandbox.mode(YmerNode.Notebook.Repo, :manual)

# The node database's repo takes no liveness guard. The notebook's has one
# because a missing sqlite-vec binary can stop that repo from starting at all;
# this one loads no extension, so a repo that is not here means application
# start failed, and raising loudly beats a suite that runs on an unowned pool.
Ecto.Adapters.SQL.Sandbox.mode(YmerNode.Repo, :manual)
