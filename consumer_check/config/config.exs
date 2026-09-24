import Config

# The one line a consumer's own configuration still sets: no dependency can set
# the time zone database for the application that takes it. Nothing else is
# configured here, so every key the node's test support fills when unset is
# unset in this project.
config :elixir, :time_zone_database, Tz.TimeZoneDatabase
