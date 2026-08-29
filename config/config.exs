import Config

# `TZID` names an IANA zone, and telling a real one from a typo needs a
# database. Without one every zone looks unknown, so a calendar object
# that omits its VTIMEZONE — which RFC 7809 explicitly permits — is
# indistinguishable from one naming a zone that does not exist.
config :elixir, :time_zone_database, Tz.TimeZoneDatabase
