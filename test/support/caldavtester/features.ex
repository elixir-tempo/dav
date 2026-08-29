defmodule Dav.CalDAVTester.Features do
  @moduledoc """
  What this server declares to the conformance suite.

  CalDAVTester gates 850 of its own blocks on `<require-feature>` and
  `<exclude-feature>`, read against a `serverinfo.xml` that describes
  *the server under test*. Apple's own file declares 84 features
  because Apple's server implements 84 features; running this server
  against that list asks it thousands of questions it never claimed to
  answer.

  So the list here is this server's, and it is deliberately short. It
  grows only when the capability is actually implemented — a feature
  declared but not built turns a conformance figure into a claim
  rather than a measurement, which is the failure this whole harness
  exists to avoid.

  ### Reading the numbers

  Two figures are worth quoting and they are not interchangeable:

  * **applicable** — tests the suite would put to a server declaring
    these features. This is the conformance denominator.

  * **whole suite** — every CalDAV test regardless of declaration,
    which measures distance from a full groupware server.

  """

  # Implemented and exercised. Each entry is a claim that can be
  # checked against the code:
  #
  #   caldav        — RFC 4791 calendar-access: MKCALENDAR, the
  #                   calendar collection type, calendar-query,
  #                   calendar-multiget, free-busy-query.
  #   COPY Method   — RFC 4918 COPY, dispatched and store-backed.
  #   MOVE Method   — RFC 4918 MOVE, likewise.
  #   regular-collection — ordinary collections may be created inside
  #                   a calendar home, which MKCOL supports.
  @declared ~w(caldav) ++ ["COPY Method", "MOVE Method", "regular-collection"]

  @doc """
  The features this server declares.

  ### Returns

  * A `MapSet` of feature names.

  ### Examples

      iex> Dav.CalDAVTester.Features.declared() |> MapSet.member?("caldav")
      true

      iex> Dav.CalDAVTester.Features.declared() |> MapSet.member?("dropbox")
      false

  """
  @spec declared() :: MapSet.t()
  def declared, do: MapSet.new(@declared)
end
