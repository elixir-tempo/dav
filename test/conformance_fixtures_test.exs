defmodule Dav.ConformanceFixturesTest do
  @moduledoc """
  Every request body in Apple's CalDAVTester fixtures, parsed.

  These are the documents real clients send, and they exercise the XML
  layer in ways tests written from the specification do not. Two bugs
  were found the first time this ran, and neither was reachable from
  the RFC text:

  * elements named by a **default namespace** rather than a prefix
    were dropped silently, making valid requests `:malformed`;

  * **non-ASCII** content was refused outright, because xmerl was
    handed codepoints where it decodes bytes.

  This is a parse-level check. It says the layer can read what clients
  send, not that the server answers correctly — that is what the rest
  of the suite is for.
  """

  use ExUnit.Case, async: true

  alias Dav.Cal.Filter
  alias Dav.Xml

  @fixtures "rfc/conformance/caldavtester/Resource"

  @reports ~w(calendar-query calendar-multiget addressbook-query addressbook-multiget
              sync-collection free-busy-query principal-property-search expand-property)

  # Classified by the document's own root element rather than by
  # searching for a name: many fixtures are expected *responses* that
  # mention a report in a supported-report-set.
  #
  # Deliberately **not** classified by parsing. Using the parser here
  # would make a file that fails to parse simply vanish from the list,
  # so the sweep would report success precisely when the layer broke —
  # which it did, the first time this was written.
  @root ~r/<\s*(?:[A-Za-z0-9_.-]+:)?([A-Za-z0-9_.-]+)(?:\s|>|\/)/

  defp bodies do
    for file <- Path.wildcard(Path.join(@fixtures, "**/*.xml")),
        body = File.read!(file),
        local = root_element(body),
        local != nil,
        do: {Path.relative_to(file, @fixtures), local, body}
  end

  defp root_element(body) do
    body
    |> String.replace(~r/<\?.*?\?>/s, "")
    |> String.replace(~r/<!--.*?-->/s, "")
    |> then(&Regex.run(@root, &1))
    |> case do
      [_all, local] -> local
      _none -> nil
    end
  end

  defp parse(body, "propfind"), do: Xml.parse_propfind(body)
  defp parse(body, "propertyupdate"), do: Xml.parse_proppatch(body)
  defp parse(body, name) when name in @reports, do: Xml.report_name(body)
  defp parse(_body, _other), do: :skip

  test "the fixtures are present — an empty sweep would pass silently" do
    assert File.dir?(@fixtures),
           "CalDAVTester fixtures are missing; see rfc/conformance/caldavtester/FETCHING.md"

    assert length(bodies()) > 500
  end

  test "a parsed name is actually a name" do
    # Parsing without failing is not the same as parsing correctly. The
    # default-namespace bug produced *successful* results with empty
    # names — a crash-only check reports that as a pass, and 17 of
    # these fixtures declare their namespace that way.
    blank =
      for {file, local, body} <- bodies(),
          local in @reports,
          {:ok, {namespace, name}} <- [Xml.report_name(body)],
          namespace == "" or name == "",
          do: file

    assert blank == [],
           "these reports parsed to a blank name:\n  " <> Enum.join(Enum.take(blank, 10), "\n  ")
  end

  test "a filter that names components yields them" do
    filters =
      for {file, "calendar-query", body} <- bodies(),
          {:ok, document} <- [Xml.parse(body)],
          element = Enum.find(document.children, &match?(%{name: {_ns, "filter"}}, &1)),
          element != nil,
          do: {file, Filter.from_element(element)}

    assert length(filters) > 50, "expected many calendar-query filters"

    broken =
      for {file, result} <- filters,
          not match?({:ok, %{name: name}} when is_binary(name), result),
          do: file

    assert broken == [],
           "these filters did not resolve to a named component:\n  " <>
             Enum.join(Enum.take(broken, 10), "\n  ")
  end

  test "every free-busy-query names a window that can be read" do
    queries =
      for {file, "free-busy-query", body} <- bodies(),
          {:ok, document} <- [Xml.parse(body)],
          do: {file, Enum.filter(document.children, &match?(%{name: {_ns, "time-range"}}, &1))}

    assert queries != [], "expected free-busy-query fixtures"

    # "which MUST contain exactly one CALDAV:time-range XML element"
    wrong = for {file, ranges} <- queries, length(ranges) != 1, do: file
    assert wrong == [], "not exactly one time-range:\n  " <> Enum.join(wrong, "\n  ")

    # CalDAVTester templates carry substitutions like
    # `$now.year.0:0101T000000Z`, which are not iCalendar values until
    # the harness fills them in. The literal ones must be readable.
    unreadable =
      for {file, [range]} <- queries,
          value <- [range.attributes["start"], range.attributes["end"]],
          is_binary(value),
          not String.contains?(value, "$"),
          match?({:error, _reason}, Tempo.from_iso8601(value)),
          do: {file, value}

    assert unreadable == [],
           "these windows could not be read:\n" <>
             Enum.map_join(unreadable, "\n", fn {file, value} -> "  #{file}: #{value}" end)
  end

  # Two fixtures are invalid on purpose: the suite sends them to check
  # that a server refuses them. Reading them successfully would be the
  # defect.
  @deliberately_invalid ~w(CardDAV/vpropfinds/4.xml CardDAV/vpropfinds/5.xml)

  test "the deliberately invalid bodies are refused" do
    for file <- @deliberately_invalid do
      body = File.read!(Path.join(@fixtures, file))

      assert Xml.parse_propfind(body) == {:error, :malformed},
             "#{file} is invalid by construction and must not parse"
    end
  end

  test "every request body a real client sends can be read" do
    failures =
      for {file, local, body} <- bodies(),
          file not in @deliberately_invalid,
          result = parse(body, local),
          result != :skip,
          match?({:error, _reason}, result),
          do: {file, local, result}

    assert failures == [],
           "these real request bodies could not be parsed:\n" <>
             Enum.map_join(failures, "\n", fn {file, local, result} ->
               "  #{file} (#{local}): #{inspect(result)}"
             end)
  end
end
