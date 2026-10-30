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
  alias Dav.CalDAVTester.Features
  alias Dav.Xml

  @path "rfc/conformance/caldavtester/scripts/server/serverinfo.xml"

  # The suite has named accounts as well as numbered ones — an
  # internationalised login among them — and every other part of the
  # harness addresses a person by number: `$calendarhome41:`,
  # `$principaluri41:`, `$userid41:`. Giving the named ones a number
  # provisions them, authenticates them and resolves their addresses
  # through the machinery that already exists, rather than a second
  # path beside it.
  @named [{41, "i18n"}]

  # A server that does not declare `split-calendars` keeps VTODOs and
  # VPOLLs in the main calendar rather than collections of their own,
  # and the suite's expectations say so — `101.ics`, written to the
  # tasks path, is expected back from a query on the calendar. Pointing
  # the paths at one collection is what "no split calendars" means.
  #
  # Named as `serverinfo.xml` names them. This read `polls` for a while,
  # which aliased `$polls1:` — a key nothing uses — and left the real
  # `$pollspath1:` pointing at a collection that does not exist. Only
  # `polls.xml` reads it, and it requires `vpoll`, so nothing noticed.
  @unsplit ~w(taskspath pollspath)

  # The block `deployed/1` rewrites, and the value it copies onto each
  # unsplit path. Matched as text rather than through `Document`: the
  # point is to hand CalDAVTester its own file back with two edits, not
  # to re-serialise it and risk every other byte.
  @features_block ~r/<features>.*?<\/features>/s

  @calendar_path ~r/<key>\$calendarpath%d:<\/key>\s*<value>([^<]*)<\/value>/

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
      {:ok, document} -> {:ok, document |> pairs() |> resolve() |> numbered()}
      error -> error
    end
  end

  @doc """
  The suite's `serverinfo.xml`, restated for this deployment.

  Apple's file describes CalendarServer: it declares every feature
  that server has and keeps tasks and polls in collections of their
  own. The in-process runner corrects for both — it declares
  `Dav.CalDAVTester.Features.declared/0` and aliases the split paths
  onto the calendar — but CalDAVTester reads the file itself, so over
  real HTTP it measured a different server: one that splits calendars,
  answers polls and implements every REPORT Apple's does.

  Two edits, and nothing else: the `<features>` block declares exactly
  what this deployment builds, and each split path is pointed at the
  calendar, the way `read/1` aliases it.

  ### Arguments

  * `path` is the serverinfo file, defaulting to the vendored one.

  ### Returns

  * `{:ok, document}`, the restated file as a string, or

  * `{:error, :malformed}` if the file cannot be read.

  ### Examples

      iex> {:ok, document} = Dav.CalDAVTester.ServerInfo.deployed()
      iex> String.contains?(document, "<feature>split-calendars</feature>")
      false

      iex> {:ok, document} = Dav.CalDAVTester.ServerInfo.deployed()
      iex> String.contains?(document, "$calendarhome%d:/$tasks:")
      false

  """
  @spec deployed(Path.t()) :: {:ok, String.t()} | {:error, :malformed}
  def deployed(path \\ @path) do
    case File.read(path) do
      {:ok, text} ->
        restated =
          text
          |> with_declared_features()
          |> with_unsplit_paths()

        {:ok, restated}

      {:error, _unreadable} ->
        {:error, :malformed}
    end
  end

  # Exactly what this deployment builds. Every feature on Apple's list
  # that is not ours turns a scenario we never claimed into a failure,
  # and a measurement that includes them is measuring CalendarServer.
  defp with_declared_features(text) do
    declared =
      Features.declared()
      |> Enum.sort()
      |> Enum.map_join("\n", &feature_line/1)

    Regex.replace(@features_block, text, fn _block ->
      "<features>\n" <> declared <> "\n\t</features>"
    end)
  end

  defp feature_line(name) do
    "\t\t<feature>" <> Xml.escape(name) <> "</feature>"
  end

  # Copied from `$calendarpath%d:` rather than written out, so the
  # aliases cannot drift from the path they stand in for.
  defp with_unsplit_paths(text) do
    case Regex.run(@calendar_path, text, capture: :all_but_first) do
      [calendar] ->
        Enum.reduce(@unsplit, text, fn name, restated ->
          repointed(restated, name, calendar)
        end)

      nil ->
        text
    end
  end

  defp repointed(text, name, calendar) do
    pattern = ~r/(<key>\$#{name}%d:<\/key>\s*<value>)[^<]*(<\/value>)/

    Regex.replace(pattern, text, fn _whole, open, close ->
      open <> calendar <> close
    end)
  end

  defp numbered(substitutions) do
    Enum.reduce(@named, substitutions, fn {index, name}, found ->
      case Map.fetch(found, "$#{name}guid:") do
        {:ok, guid} -> Map.merge(found, slots(found, index, name, guid))
        :error -> found
      end
    end)
  end

  defp slots(substitutions, index, name, guid) do
    homes = Map.get(substitutions, "$calendars_uids:", "/calendars/__uids__/")
    principals = Map.get(substitutions, "$principals_uids:", "/principals/__uids__/")

    %{
      "$userid#{index}:" => Map.get(substitutions, "$#{name}id:"),
      "$pswd#{index}:" => Map.get(substitutions, "$#{name}pswd:"),
      "$username#{index}:" => Map.get(substitutions, "$#{name}name:"),
      "$email#{index}:" => Map.get(substitutions, "$#{name}email:"),
      "$cuaddr#{index}:" => Map.get(substitutions, "$#{name}cuaddr:"),
      "$cuaddrurn#{index}:" => Map.get(substitutions, "$#{name}cuaddrurn:"),
      "$calendarhome#{index}:" => "#{homes}#{guid}",
      "$principaluri#{index}:" => "#{principals}#{guid}/"
    }
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
    Regex.replace(~r/\$[A-Za-z0-9_.\-]+:/, bare(text, substitutions), fn key ->
      case Map.fetch(substitutions, key) do
        {:ok, value} -> value
        :error -> dynamic(key)
      end
    end)
  end

  # A bare `$` is the suite's name for "the resource the last GETNEW
  # found". It has no trailing colon, so the general pattern cannot
  # match it, and it is only a variable when it stands alone.
  defp bare(text, substitutions) do
    case Map.fetch(substitutions, "$") do
      {:ok, value} when text == "$" -> value
      _not_bound_or_not_bare -> text
    end
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

  defp pairs(document) do
    document
    |> elements("substitutions")
    |> Enum.flat_map(&entries/1)
    |> Map.new()
    |> Map.merge(harness(document))
    |> unsplit()
  end

  # The harness's own variables, which upstream computes from the
  # server it is pointed at rather than declaring in the file — so
  # these are computed the same way, from the same three elements.
  # `$host:` prefixes every `Destination` header in the suite, and
  # left unexpanded it makes each COPY and MOVE look like a request to
  # another server: answered `502`, with no body, so the test reports
  # "not valid XML" and the real cause stays hidden.
  #
  # They have to be the address the server actually answers at, and
  # not a placeholder. Held at `Plug.Test`'s own `www.example.com`,
  # the in-process driver compared our expansion against itself and
  # agreed every time, while the real one put Python's expansion —
  # computed from these same three elements — beside ours and found
  # them different: `well-known` expects a `Location` of `$hostssl:/`
  # and got `https://www.example.com/`.
  defp harness(document) do
    host = declared(document, "host")
    port = declared(document, "nonsslport")
    secure = declared(document, "sslport")

    %{
      "$host:" => "http://#{host}:#{port}",
      "$hostssl:" => "https://#{host}:#{secure}",
      "$port:" => port,
      "$sslport:" => secure
    }
  end

  defp declared(document, name) do
    case elements(document, name) do
      [%{text: text} | _rest] -> text
      [] -> ""
    end
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
