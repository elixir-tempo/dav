defmodule Dav.CalDAVTester.ServerInfo do
  @moduledoc """
  The substitution environment the CalDAVTester scenarios are written against.

  Every scenario names resources indirectly — `$calendarhome1:`,
  `$calendarpath1:`, `$userid1:` — and `scripts/server/serverinfo.xml`
  says what those expand to. Without it a scenario is a template with
  no values, which is why the suite cannot be read, let alone run,
  from the scenario files alone.

  Three things are going on in that file:

  * flat `<key>`/`<value>` pairs;

  * `<repeat count="40">` blocks whose keys carry `%d` and `%02d`, one
    set per user, so `$userid1:` through `$userid40:` all exist; and

  * values that reference other keys, so `$calendars:` is
    `$root:calendars/` and resolves only after `$root:` does.

  """

  alias Dav.CalDAVTester.Document

  @path "rfc/conformance/caldavtester/scripts/server/serverinfo.xml"

  @doc """
  Read the substitution environment.

  ### Arguments

  * `path` is the serverinfo file, defaulting to the vendored one.

  ### Returns

  * `{:ok, substitutions}`, a map of `"$key:"` to its resolved value; or

  * `{:error, :malformed}` if the file cannot be read as XML.

  ### Examples

      iex> {:ok, substitutions} = Dav.CalDAVTester.ServerInfo.read()
      iex> substitutions["$userid1:"]
      "user01"

      iex> {:ok, substitutions} = Dav.CalDAVTester.ServerInfo.read()
      iex> substitutions["$calendars:"]
      "/calendars/"

  """
  @spec read(Path.t()) :: {:ok, %{optional(String.t()) => String.t()}} | {:error, :malformed}
  def read(path \\ @path) do
    case Document.read(path) do
      {:ok, document} -> {:ok, document |> pairs() |> resolve()}
      error -> error
    end
  end

  @doc """
  Expand every `$key:` in a string.

  ### Arguments

  * `text` is scenario text, a request URI, or a request body.

  * `substitutions` is the map from `read/1`.

  ### Returns

  * The text with every known key replaced. An unknown key is left
    alone rather than blanked, so it shows up in a failure instead of
    silently becoming an empty path segment.

  ### Examples

      iex> {:ok, substitutions} = Dav.CalDAVTester.ServerInfo.read()
      iex> Dav.CalDAVTester.ServerInfo.expand("$calendarhome1:/", substitutions)
      "/calendars/__uids__/10000000-0000-0000-0000-000000000001/"

  """
  @spec expand(String.t(), %{optional(String.t()) => String.t()}) :: String.t()
  def expand(text, substitutions) do
    Regex.replace(~r/\$[A-Za-z0-9_.\-]+:/, text, fn key ->
      case Map.fetch(substitutions, key) do
        {:ok, value} -> value
        :error -> dynamic(key)
      end
    end)
  end

  @doc """
  Expand a substitution the server info file cannot hold.

  Some of the suite's variables are computed per use rather than
  declared: dates relative to today, and fresh `UID`s. They are the
  reason a fixture can be reused — `$uidrandom:` is what stops the
  same event body colliding with itself, and `$now.year.1:` is what
  keeps a fixture written in 2007 in the future.

  Leaving them unexpanded is not harmless. It writes the literal text
  `$uidrandom:` into every `UID`, so the twenty-fourth fixture to use
  it collides with the first, and a server enforcing
  `CALDAV:no-uid-conflict` correctly refuses a request the suite
  expects to succeed.

  ### Arguments

  * `key` is the unexpanded variable, including its `$` and `:`.

  ### Returns

  * The computed value, or the key unchanged when it is not one of
    these — an unknown variable stays visible rather than becoming an
    empty string.

  ### Examples

      iex> Dav.CalDAVTester.ServerInfo.dynamic("$now.year.0:") == "#{Date.utc_today().year}"
      true

      iex> Dav.CalDAVTester.ServerInfo.dynamic("$uidrandom:") != Dav.CalDAVTester.ServerInfo.dynamic("$uidrandom:")
      true

      iex> Dav.CalDAVTester.ServerInfo.dynamic("$unknown:")
      "$unknown:"

  """
  @spec dynamic(String.t()) :: String.t()
  def dynamic(key) do
    case key do
      "$now:" -> stamp(0)
      "$uidrandom:" -> uuid()
      "$now.year." <> rest -> year(rest)
      "$now." <> rest -> day(rest)
      "$uid" <> rest -> stable(rest)
      _unknown -> key
    end
  end

  # `$now.year.1:0101T100000` is next year followed by a literal date,
  # so this yields the year alone.
  defp year(rest) do
    case Integer.parse(String.trim_trailing(rest, ":")) do
      {offset, ""} -> "#{Date.utc_today().year + offset}"
      _unreadable -> "$now.year." <> rest
    end
  end

  # `$now.1:T180000` is tomorrow followed by a literal time.
  defp day(rest) do
    case Integer.parse(String.trim_trailing(rest, ":")) do
      {offset, ""} -> stamp(offset)
      _unreadable -> "$now." <> rest
    end
  end

  defp stamp(offset) do
    Date.utc_today() |> Date.add(offset) |> Calendar.strftime("%Y%m%d")
  end

  # `$uid1:` names the same UID everywhere it appears in a run, which
  # is what lets one fixture reference another's event.
  defp stable(rest) do
    index = String.trim_trailing(rest, ":")

    if index =~ ~r/^[0-9]+$/ do
      "caldavtester-uid-" <> String.pad_leading(index, 4, "0")
    else
      "$uid" <> rest
    end
  end

  defp uuid do
    16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
  end

  ## --- reading ----------------------------------------------------

  # The harness's own variables, which upstream computes from the
  # server it is pointed at rather than declaring in the file. `$host:`
  # prefixes every `Destination` header in the suite, and left
  # unexpanded it makes each COPY and MOVE look like a request to
  # another server — answered `502`, with no body, so the test reports
  # "not valid XML" and the real cause stays hidden.
  #
  # Requests here go straight to the plug, so the host is the one
  # `Plug.Test` gives them.
  @harness %{
    "$host:" => "http://www.example.com",
    "$hostssl:" => "https://www.example.com",
    "$port:" => "80",
    "$sslport:" => "443"
  }

  # A server that does not declare `split-calendars` keeps VTODOs in
  # the main calendar rather than a separate collection, and the
  # suite's expectations say so — `101.ics`, written to the tasks path,
  # is expected back from a query on the calendar. Pointing the two
  # paths at one collection is what "no split calendars" means.
  @unsplit ~w(taskspath polls)

  defp pairs(document) do
    document
    |> elements("substitutions")
    |> Enum.flat_map(&entries/1)
    |> Map.new()
    |> Map.merge(@harness)
    |> unsplit()
  end

  defp unsplit(substitutions) do
    aliases =
      for name <- @unsplit,
          index <- 1..40//1,
          calendar = Map.get(substitutions, "$calendarpath#{index}:"),
          is_binary(calendar),
          into: %{},
          do: {"$#{name}#{index}:", calendar}

    Map.merge(substitutions, aliases)
  end

  defp entries(container) do
    Enum.flat_map(container.children, fn
      %{name: {_ns, "substitution"}} = element -> [pair(element)]
      %{name: {_ns, "repeat"}} = element -> repeated(element)
      _other -> []
    end)
  end

  # A repeat block is one set of keys per index: `$userid%d:` becomes
  # `$userid1:` through `$userid40:`, and the value is formatted with
  # the same index so they line up.
  defp repeated(element) do
    count = String.to_integer(Map.get(element.attributes, "count", "0"))

    for index <- 1..count//1,
        %{name: {_ns, "substitution"}} = child <- element.children,
        {key, value} = pair(child),
        do: {format(key, index), format(value, index)}
  end

  defp pair(element) do
    {text(element, "key"), text(element, "value")}
  end

  defp text(element, name) do
    case Enum.find(element.children, &match?(%{name: {_ns, ^name}}, &1)) do
      nil -> ""
      child -> child.text
    end
  end

  # `%%` is a literal percent, so it is consumed first and restored
  # last — otherwise `User%%20%02d` yields a substitution rather than
  # the escaped `%20` the suite means.
  defp format(template, index) do
    template
    |> String.replace("%%", "\0")
    |> String.replace("%02d", String.pad_leading("#{index}", 2, "0"))
    |> String.replace("%03d", String.pad_leading("#{index}", 3, "0"))
    |> String.replace("%d", "#{index}")
    |> String.replace("\0", "%")
  end

  # Values reference other values, so one pass is not enough. Repeated
  # until nothing changes, with a bound: a cycle would otherwise spin
  # here rather than failing.
  defp resolve(substitutions), do: resolve(substitutions, 10)

  defp resolve(substitutions, 0), do: substitutions

  defp resolve(substitutions, budget) do
    expanded =
      Map.new(substitutions, fn {key, value} -> {key, statically(value, substitutions)} end)

    if expanded == substitutions, do: expanded, else: resolve(expanded, budget - 1)
  end

  # Resolving the table itself must not compute the dynamic values: a
  # `$uidrandom:` baked into a stored value would be the same UID
  # everywhere it was used, which is the opposite of what it means.
  # They are computed per use, in `expand/2`.
  defp statically(text, substitutions) do
    Regex.replace(~r/\$[A-Za-z0-9_.\-]+:/, text, &Map.get(substitutions, &1, &1))
  end

  defp elements(element, name) do
    matching = for child <- element.children, match?(%{name: {_ns, ^name}}, child), do: child
    matching ++ Enum.flat_map(element.children, &elements(&1, name))
  end
end
