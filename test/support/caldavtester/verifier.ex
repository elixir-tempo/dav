defmodule Dav.CalDAVTester.Verifier do
  @moduledoc """
  The response checks the scenarios call for, ported from `verifiers/`.

  Each is a faithful port of the Python in
  `rfc/conformance/caldavtester/verifiers`, and the semantics are
  theirs rather than a reasonable reading of them — `statusCode`
  defaults to *any* 2xx, and a `header` argument's leading `!` or `*`
  changes what presence means.

  A callback that is not implemented returns `{:skipped, reason}`, so
  a scenario that depends on it is reported as unmeasured rather than
  passing by omission.

  """

  alias Dav.Cal.ICalendar
  alias Dav.CalDAVTester.Calendars
  alias Dav.CalDAVTester.Scenario.Verify
  alias Dav.CalDAVTester.ServerInfo
  alias Dav.Xml
  alias Plug.Conn

  @typedoc "The result of one check."
  @type outcome :: :passed | {:failed, String.t()} | {:skipped, String.t()}

  @doc """
  Run one verifier against a response.

  ### Arguments

  * `verify` is a `t:Dav.CalDAVTester.Scenario.Verify.t/0`.

  * `conn` is the `Plug.Conn` the request returned.

  ### Returns

  * `:passed`, `{:failed, reason}`, or `{:skipped, reason}`.

  """
  @spec run(Verify.t(), Plug.Conn.t(), map()) :: outcome()
  def run(verify, conn, substitutions \\ %{})

  def run(%Verify{callback: "statusCode", args: args}, conn, _substitutions) do
    expected = Map.get(args, "status", ["2xx"])

    if Enum.any?(expected, &status_matches?(&1, conn.status)) do
      :passed
    else
      # The body carries the precondition on a 403 or 409, which is the
      # difference between "it refused" and knowing which rule refused.
      {:failed, "status #{conn.status}, expected #{Enum.join(expected, ", ")}#{detail(conn)}"}
    end
  end

  def run(%Verify{callback: "header", args: args}, conn, _substitutions) do
    args |> Map.get("header", []) |> each(&header_matches(&1, conn))
  end

  def run(%Verify{callback: "multistatusItems", args: args}, conn, _substitutions) do
    with :ok <- multistatus_status(conn),
         {:ok, responses} <- responses(conn) do
      multistatus_items(args, responses, conn)
    end
  end

  def run(%Verify{callback: "propfindItems", args: args}, conn, _substitutions) do
    expected = args |> Map.get("status", ["207"]) |> List.first() |> String.to_integer()

    with :ok <- expect_status(conn, expected),
         {:ok, responses} <- responses(conn) do
      propfind_items(args, responses)
    end
  end

  def run(%Verify{callback: "dataString", args: args}, conn, _substitutions) do
    data = unwrapped(conn.resp_body, args)

    cond do
      Map.has_key?(args, "empty") and data != "" -> {:failed, "response has a body"}
      Map.has_key?(args, "empty") -> :passed
      data == "" -> {:failed, "no response body"}
      true -> data_string(data, args)
    end
  end

  def run(%Verify{callback: "prepostcondition", args: args}, conn, _substitutions) do
    codes = Map.get(args, "status", ~w(403 409 507))

    with :ok <- status_in(conn, codes),
         {:ok, document} <- document(conn),
         :ok <- rooted(document, "error") do
      preconditions(document, Map.get(args, "error", []), args)
    end
  end

  def run(%Verify{callback: "dataMatch", args: args}, conn, substitutions) do
    with :ok <- status_in(conn, ~w(200 207)),
         {:ok, expected} <- data_file(args, substitutions) do
      if normalise(conn.resp_body) == normalise(expected) do
        :passed
      else
        {:failed, "response does not match #{args |> Map.get("filepath", []) |> List.first()}"}
      end
    end
  end

  def run(%Verify{callback: "calendarDataMatch", args: args}, conn, substitutions) do
    codes = Map.get(args, "status", ~w(200 201 207))

    with :ok <- status_in(conn, codes),
         {:ok, expected} <- calendar_expected(args, substitutions) do
      Calendars.compare(conn.resp_body, expected, Map.get(args, "filter", []))
    end
  end

  def run(%Verify{callback: "xmlElementMatch", args: args}, conn, _substitutions) do
    with :ok <- status_in(conn, ~w(200 207)),
         {:ok, document} <- document(conn),
         {:ok, root} <- parent(document, Map.get(args, "parent", [])) do
      element_match(root, args)
    end
  end

  # Upstream's `aclItems`: every `DAV:response` in the multistatus
  # must show, inside its `DAV:current-user-privilege-set`, all the
  # privileges named `granted` and none named `denied`.
  def run(%Verify{callback: "aclItems", args: args}, conn, _substitutions) do
    with :ok <- expect_status(conn, 207),
         {:ok, document} <- document(conn) do
      privilege_items(document, Map.get(args, "granted", []), Map.get(args, "denied", []))
    end
  end

  def run(%Verify{callback: "freeBusy", args: args}, conn, _substitutions) do
    with :ok <- expect_status(conn, 200),
         {:ok, periods} <- free_busy(conn.resp_body) do
      free_busy_matches(periods, args)
    end
  end

  def run(%Verify{callback: "xmlDataMatch", args: args}, conn, substitutions) do
    with :ok <- status_in(conn, ~w(200 207)),
         {:ok, expected} <- data_file(args, substitutions),
         {:ok, actual} <- document(conn),
         {:ok, wanted} <- parsed(expected) do
      filters = Map.get(args, "filter", [])

      if same?(strip(actual, filters), strip(wanted, filters)) do
        :passed
      else
        {:failed,
         "XML differs from #{args |> Map.get("filepath", []) |> List.first()}: " <>
           difference(strip(actual, filters), strip(wanted, filters))}
      end
    end
  end

  def run(%Verify{callback: "postFreeBusy", args: args}, conn, _substitutions) do
    with :ok <- expect_status(conn, 200),
         {:ok, document} <- document(conn) do
      post_free_busy(document, args)
    end
  end

  def run(%Verify{callback: "propfindValues", args: args}, conn, _substitutions) do
    with :ok <- expect_status(conn, 207),
         {:ok, responses} <- responses(conn) do
      each(specifications(args, "props"), &property_value(&1, responses, args))
    end
  end

  def run(%Verify{callback: "jsonPointerMatch", args: args}, conn, _substitutions) do
    with :ok <- status_in(conn, Map.get(args, "status", ["200"])),
         :ok <- json_typed(conn),
         {:ok, document} <- decoded(conn.resp_body) do
      json_pointers(document, args)
    end
  end

  def run(%Verify{callback: callback}, _conn, _substitutions) do
    {:skipped, "verifier #{callback} is not implemented"}
  end

  ## --- data verifiers ---------------------------------------------

  # `unwrap` undoes iCalendar line folding before matching, so a test
  # can name a value that the wire form has split across lines.
  defp unwrapped(body, args) do
    if Map.has_key?(args, "unwrap"), do: String.replace(body, "\r\n ", ""), else: body
  end

  defp data_string(data, args) do
    checks =
      Enum.map(Map.get(args, "equals", []), &{:equals, &1}) ++
        Enum.map(Map.get(args, "contains", []), &{:contains, &1}) ++
        Enum.map(Map.get(args, "notcontains", []), &{:notcontains, &1})

    each(checks, &data_check(&1, data))
  end

  defp data_check({:equals, item}, data) do
    if data == item, do: :passed, else: {:failed, "response does not equal #{inspect(item)}"}
  end

  # A test writes newlines as `\n`; the wire uses CRLF. Upstream looks
  # for both, so a match either way counts.
  defp data_check({:contains, item}, data) do
    if contains?(data, item), do: :passed, else: {:failed, "missing #{inspect(item)}"}
  end

  defp data_check({:notcontains, item}, data) do
    if contains?(data, item), do: {:failed, "contains #{inspect(item)}"}, else: :passed
  end

  defp contains?(data, item) do
    String.contains?(data, String.replace(item, "\n", "\r\n")) or String.contains?(data, item)
  end

  defp status_in(conn, codes) do
    if "#{conn.status}" in codes, do: :ok, else: {:failed, "status #{conn.status}"}
  end

  # The body is quoted in the failure because "not valid XML" on its
  # own hides the usual cause, which is a body that is empty or is not
  # XML at all rather than one that is malformed.
  defp named?(%{name: {_namespace, local}}, local), do: true
  defp named?(_element, _local), do: false

  defp privilege_items(document, granted, denied) do
    document.children
    |> Enum.filter(&named?(&1, "response"))
    |> Enum.map(fn response ->
      held = MapSet.new(held_privileges(response))
      missing = Enum.reject(granted, &MapSet.member?(held, &1))
      present = Enum.filter(denied, &MapSet.member?(held, &1))
      {missing, present}
    end)
    |> Enum.reject(&(&1 == {[], []}))
    |> case do
      [] ->
        :passed

      [{missing, present} | _rest] ->
        {:failed,
         "privileges missing: #{inspect(missing)}; privileges that should be denied: #{inspect(present)}"}
    end
  end

  defp held_privileges(element) do
    if named?(element, "current-user-privilege-set") do
      for privilege <- element.children,
          named?(privilege, "privilege"),
          %{name: {namespace, local}} <- privilege.children,
          do: "{#{namespace}}#{local}"
    else
      Enum.flat_map(element.children, &held_privileges/1)
    end
  end

  defp document(conn) do
    case Xml.parse(conn.resp_body) do
      {:ok, document} -> {:ok, document}
      _unparseable -> {:failed, "not valid XML: #{inspect(String.slice(conn.resp_body, 0, 60))}"}
    end
  end

  defp rooted(%{name: {_namespace, name}}, name), do: :ok
  defp rooted(_document, name), do: {:failed, "root element is not DAV:#{name}"}

  # The error document names the conditions that failed, and the set
  # must match exactly — a server reporting an extra condition is
  # reporting something different from what the test expected.
  # `error-description` is prose rather than a condition, so upstream
  # drops it and so does this.
  @description "{http://twistedmatrix.com/xml_namespace/dav/}error-description"

  defp preconditions(document, expected, args) do
    got =
      for child <- document.children,
          name = clark(child.name),
          name != @description,
          into: MapSet.new(),
          do: name

    wanted = MapSet.new(expected)
    missing = MapSet.difference(wanted, got)

    extra =
      if Map.has_key?(args, "ignoreextras"),
        do: MapSet.new(),
        else: MapSet.difference(got, wanted)

    cond do
      MapSet.size(missing) > 0 ->
        {:failed, "conditions not returned: #{inspect(Enum.to_list(missing))}"}

      MapSet.size(extra) > 0 ->
        {:failed, "unexpected conditions: #{inspect(Enum.to_list(extra))}"}

      true ->
        :passed
    end
  end

  defp data_file(args, substitutions) do
    case Map.get(args, "filepath", []) do
      [path] -> read_fixture(path, substitutions)
      _none_or_many -> {:failed, "no file to compare against"}
    end
  end

  # The fixture is expanded exactly as it was when the request sent it.
  # Comparing a stored `20270101T100000` against a file still reading
  # `$now.year.1:0101T100000` reports every dated fixture as a
  # mismatch — the server is right and the comparison is wrong.
  defp read_fixture(path, substitutions) do
    case File.read(Path.join("rfc/conformance/caldavtester", path)) do
      {:ok, contents} -> {:ok, ServerInfo.expand(contents, substitutions)}
      _missing -> {:failed, "fixture #{path} is missing"}
    end
  end

  defp calendar_expected(args, substitutions) do
    case {Map.get(args, "filepath", []), Map.get(args, "data", [])} do
      {[path], _data} -> read_fixture(path, substitutions)
      {_files, [data]} -> {:ok, data}
      _neither -> {:failed, "no calendar data to compare against"}
    end
  end

  defp normalise(text), do: text |> String.replace("\r\n", "\n") |> String.trim()

  ## --- propfindValues ---------------------------------------------

  # `propfindItems` checks which properties came back; this checks
  # what they *say*. A server can report every property a client asked
  # for and still have the values wrong, and only this notices.
  defp property_value({name, expected}, responses, args) do
    found =
      for response <- selected(responses, args),
          propstat <- response.propstats,
          {property, value} <- values_in(propstat),
          property == name,
          do: value

    cond do
      found == [] -> {:failed, "#{name} was not returned"}
      is_nil(expected) -> :passed
      expected == :negated -> :passed
      Enum.any?(found, &alike?(&1, expected)) -> :passed
      true -> {:failed, "#{name} is #{inspect(hd(found))}, expected #{inspect(expected)}"}
    end
  end

  # A property whose value is markup is compared as markup. Both sides
  # name the same elements, but a prefix is a serialisation choice —
  # `<D:href>` and `<href xmlns="DAV:">` are the same element — and
  # comparing the strings makes the server fail for spelling a
  # namespace differently from the scenario that wrote the
  # expectation. The same reasoning as `xmlDataMatch`, applied where
  # the value is a document fragment rather than a whole one.
  defp alike?(found, expected) do
    found == expected or fragments_alike?(found, expected)
  end

  defp fragments_alike?(found, expected) do
    with true <- markup?(found) and markup?(expected),
         {:ok, left} <- parsed(wrapped(found)),
         {:ok, right} <- parsed(wrapped(expected)) do
      same?(left, right)
    else
      _not_markup_or_unreadable -> false
    end
  end

  defp markup?(value), do: is_binary(value) and String.contains?(value, "<")

  # `ignore` and `only` narrow which resources are examined, so a
  # collection's own response does not have to satisfy expectations
  # written for its members.
  defp selected(responses, args) do
    ignored = Map.get(args, "ignore", [])

    case Map.get(args, "only", []) do
      [] -> Enum.reject(responses, &(&1.href in ignored))
      only -> Enum.filter(responses, &(&1.href in only))
    end
  end

  defp values_in(propstat) do
    case Enum.find(propstat.children, &local?(&1, "prop")) do
      nil -> []
      prop -> for child <- prop.children, do: {clark(child.name), String.trim(child.text)}
    end
  end

  ## --- xmlDataMatch -----------------------------------------------

  # Upstream normalises both sides through ElementTree's serialiser and
  # compares the strings. That output cannot be reproduced here, so the
  # comparison is structural instead: names, attributes, text and
  # children, with children sorted. It is a stricter test of the same
  # thing — two documents that differ only in element order compare
  # equal, and two that differ in content do not.
  defp same?(left, right) do
    shape(left) == shape(right)
  end

  # Which part differs, not merely that something does. A sharing
  # notification is thirty elements deep and naming the first mismatch
  # is the difference between a fix and a guess.
  defp difference(left, right) do
    got = flattened(left, "")
    wanted = flattened(right, "")

    missing = wanted -- got
    unexpected = got -- wanted

    "missing #{inspect(Enum.take(missing, 3))}, unexpected #{inspect(Enum.take(unexpected, 3))}"
  end

  defp flattened(%{name: name, text: text, children: children} = element, prefix) do
    attributes =
      element.attributes
      |> declared()
      |> Enum.sort()
      |> Enum.map_join(",", fn {key, value} -> "#{key}=#{value}" end)

    here =
      prefix <>
        "/" <>
        elem(name, 0) <>
        ":" <> elem(name, 1) <> if(attributes == "", do: "", else: "[#{attributes}]")

    leaf =
      case located(name, text) do
        "" -> [here]
        value -> [here <> "=" <> value]
      end

    leaf ++ Enum.flat_map(children, &flattened(&1, here))
  end

  defp shape(%{name: name, attributes: attributes, text: text, children: children}) do
    {name, declared(attributes), located(name, text),
     children |> Enum.map(&shape/1) |> Enum.sort()}
  end

  # A collection is named with or without its trailing slash, and both
  # spellings address it. Comparing them as different text makes a
  # server fail for a punctuation choice the specification leaves open.
  defp located({"DAV:", "href"}, text), do: text |> String.trim() |> String.trim_trailing("/")

  defp located(_name, text), do: String.trim(text)

  # Namespace declarations are not content. `<D:href>` and
  # `<href xmlns="DAV:">` are the same element written two ways, and
  # the parser has already resolved both to the same qualified name —
  # keeping the `xmlns` attribute alongside it makes the two compare
  # unequal for a choice of prefix.
  defp declared(attributes) do
    for {name, value} <- attributes,
        not (name == "xmlns" or String.starts_with?(name, "xmlns:")),
        into: %{},
        do: {name, value}
  end

  # A `filter` names elements the comparison ignores — timestamps and
  # generated identifiers that could never match.
  defp strip(element, []), do: element

  defp strip(element, filters) do
    kept =
      element.children
      |> Enum.reject(&(clark(&1.name) in filters or elem(&1.name, 1) in filters))
      |> Enum.map(&strip(&1, filters))

    %{element | children: kept}
  end

  defp parsed(text) do
    case Xml.parse(text) do
      {:ok, document} -> {:ok, document}
      _unparseable -> {:failed, "the expected document is not valid XML"}
    end
  end

  ## --- postFreeBusy -----------------------------------------------

  # A `schedule-response` carrying one VFREEBUSY per attendee. Each
  # named attendee must appear once, with the periods expected of them
  # — an answer that reports the right times for the wrong person is
  # not a lesser failure than reporting the wrong times.
  defp post_free_busy(document, args) do
    entries =
      for response <- elements(document, "response"),
          data <- elements(response, "calendar-data"),
          {:ok, calendar} <- [ICalendar.parse(data.text)],
          component <- calendar.components,
          component.name == "VFREEBUSY",
          do: {component, Enum.count(calendar.components, &(&1.name == "VEVENT"))}

    each(Map.get(args, "attendee", []), &attendee_busy(&1, entries, args))
  end

  defp attendee_busy(attendee, entries, args) do
    case Enum.find(entries, fn {component, _events} -> attends?(component, attendee) end) do
      nil ->
        {:failed, "no VFREEBUSY for #{attendee}"}

      {component, events} ->
        with :passed <- free_busy_matches(periods_by_type(component), args) do
          counted_events(events, args)
        end
    end
  end

  # An extended answer carries the events themselves beside the
  # periods — as many as the asker is entitled to see.
  defp counted_events(events, args) do
    case Map.get(args, "events") do
      [expected] -> compare(Integer.to_string(events), expected, "VEVENTs")
      _uncounted -> :passed
    end
  end

  defp attends?(component, attendee) do
    Enum.any?(component.properties, &(&1.name == "ATTENDEE" and &1.value == attendee))
  end

  ## --- freeBusy ---------------------------------------------------

  # The response is one VFREEBUSY, and its FREEBUSY properties are
  # compared as *sets* per FBTYPE. Order carries no meaning — two
  # servers may coalesce and emit in different orders and both be
  # right — but the sets must match exactly, so a period the server
  # invented fails just as loudly as one it lost.
  defp free_busy(body) do
    with {:ok, calendar} <- ICalendar.parse(body),
         [component] <- Enum.filter(calendar.components, &(&1.name == "VFREEBUSY")) do
      {:ok, periods_by_type(component)}
    else
      _not_one_vfreebusy -> {:failed, "response is not a single VFREEBUSY"}
    end
  end

  defp periods_by_type(component) do
    for property <- component.properties,
        property.name == "FREEBUSY",
        type = Map.get(property.parameters, "FBTYPE", "BUSY"),
        period <- String.split(property.value, ","),
        instants = spanned(period),
        reduce: %{} do
      found -> Map.update(found, type, [instants], &[instants | &1])
    end
  end

  # RFC 5545 section 3.3.9 writes a period either as two instants or
  # as a start and a duration, and both name the same span. Compared
  # as text they never match, so both are read into the same form
  # before the sets are compared.
  defp spanned(period) do
    case String.split(period, "/", parts: 2) do
      [start, "P" <> _rest = duration] -> start <> "/" <> shifted(start, duration)
      _two_instants -> period
    end
  end

  defp shifted(start, duration) do
    with {:ok, from} <- instant(start),
         {:ok, seconds} <- lasting(duration) do
      from |> DateTime.add(seconds, :second) |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    else
      _unreadable -> duration
    end
  end

  defp instant(<<y::binary-4, m::binary-2, d::binary-2, "T", rest::binary>>) do
    with <<hh::binary-2, mm::binary-2, ss::binary-2, _zone::binary>> <- rest,
         {:ok, date} <- Date.from_iso8601("#{y}-#{m}-#{d}"),
         {:ok, time} <- Time.from_iso8601("#{hh}:#{mm}:#{ss}") do
      DateTime.new(date, time, "Etc/UTC")
    else
      _unreadable -> :error
    end
  end

  defp instant(_other), do: :error

  @units %{"D" => 86_400, "W" => 604_800, "H" => 3600, "M" => 60, "S" => 1}

  defp lasting("P" <> rest) do
    case Regex.scan(~r/(\d+)([DWHMS])/, rest) do
      [] ->
        :error

      matched ->
        {:ok, Enum.sum(for [_all, n, u] <- matched, do: String.to_integer(n) * @units[u])}
    end
  end

  defp lasting(_other), do: :error

  @prefixes %{
    "DAV:" => "D",
    "urn:ietf:params:xml:ns:caldav" => "C",
    "http://calendarserver.org/ns/" => "CS"
  }

  @free_busy_types %{
    "busy" => "BUSY",
    "tentative" => "BUSY-TENTATIVE",
    "unavailable" => "BUSY-UNAVAILABLE"
  }

  defp free_busy_matches(periods, args) do
    each(Map.to_list(@free_busy_types), fn {argument, type} ->
      expected = MapSet.new(Map.get(args, argument, []))
      actual = MapSet.new(Map.get(periods, type, []))

      if MapSet.equal?(expected, actual) do
        :passed
      else
        {:failed,
         "#{type} periods differ: missing #{inspect(Enum.take(MapSet.difference(expected, actual), 3))}, " <>
           "unexpected #{inspect(Enum.take(MapSet.difference(actual, expected), 3))}"}
      end
    end)
  end

  ## --- xmlElementMatch --------------------------------------------

  # A path predicate quotes its value either way — `[@a='b']` and
  # `[@a="b"]` both appear in the suite — and a comparison that strips
  # only one of them never matches the other.
  defp unquoted(value), do: value |> String.trim("'") |> String.trim("\"")

  defp parent(document, []), do: {:ok, document}

  defp parent(document, [path]) do
    case nodes_for(document, path) do
      [node] -> {:ok, node}
      [] -> {:failed, "missing parent node #{path}"}
      _many -> {:failed, "too many parent nodes #{path}"}
    end
  end

  defp element_match(root, args) do
    exists = Enum.map(Map.get(args, "exists", []), &{:exists, &1})
    absent = Enum.map(Map.get(args, "notexists", []), &{:notexists, &1})

    each(exists ++ absent, &path_check(&1, root))
  end

  defp path_check({:exists, path}, root) do
    if nodes_for(root, path) == [], do: {:failed, "missing #{path}"}, else: :passed
  end

  defp path_check({:notexists, path}, root) do
    if nodes_for(root, path) == [], do: :passed, else: {:failed, "unexpected #{path}"}
  end

  # A path is `/{ns}root/{ns}child` with optional `[test]` predicates.
  # The leading step names the root itself; the rest descend.
  defp nodes_for(root, path) do
    {steps, tests} = split_path(path)

    steps
    |> Enum.reduce([root], fn step, nodes -> Enum.flat_map(nodes, &step_into(&1, step)) end)
    |> Enum.filter(fn node -> Enum.all?(tests, &test_node(node, &1)) end)
  end

  defp split_path(path) do
    [names | tests] = String.split(path, "[")

    steps = names |> String.trim_leading("/") |> segments() |> Enum.reject(&(&1 == ""))

    {steps, Enum.map(tests, &String.trim_trailing(&1, "]"))}
  end

  # A step is Clark notation, and a namespace URI has `/` in it. Only
  # the slashes *between* steps separate anything — splitting on all
  # of them turns `{http://calendarserver.org/ns/}invite` into pieces
  # that name no element.
  defp segments(names) do
    case Regex.scan(~r/\{[^}]*\}[^\/]*/, names) do
      [] -> String.split(names, "/")
      matched -> List.flatten(matched)
    end
  end

  # The first step names the node already in hand rather than one of
  # its children, which is how upstream anchors an absolute path.
  defp step_into(node, step) do
    if clark(node.name) == step do
      [node]
    else
      Enum.filter(node.children, &(clark(&1.name) == step))
    end
  end

  defp test_node(node, "@" <> test) do
    case String.split(test, "=", parts: 2) do
      [attribute] -> Map.has_key?(node.attributes, attribute)
      [attribute, value] -> Map.get(node.attributes, attribute) == unquoted(value)
    end
  end

  defp test_node(node, "=" <> value), do: same_text?(String.trim(node.text), value)
  defp test_node(node, "!" <> value), do: String.trim(node.text) != value
  defp test_node(node, "*" <> value), do: String.contains?(node.text, value)
  defp test_node(node, "$" <> value), do: not String.contains?(node.text, value)
  defp test_node(node, "+" <> value), do: String.starts_with?(String.trim(node.text), value)

  defp test_node(node, "^" <> test) do
    {name, value} =
      case String.split(test, "=", parts: 2) do
        [name] -> {name, nil}
        [name, value] -> {name, value}
      end

    Enum.any?(node.children, fn child ->
      clark(child.name) == name and (value == nil or same_text?(String.trim(child.text), value))
    end)
  end

  defp test_node(node, "||"), do: String.trim(node.text) != "" or node.children != []

  defp test_node(_node, _unknown), do: true

  # An href's trailing slash is a serialisation choice — upstream
  # emits collection hrefs with one, expectations are written with
  # and without — so href-shaped values compare with it trimmed, the
  # same way `multistatusItems` compares its href sets.
  defp same_text?(text, value) do
    if String.starts_with?(value, "/"),
      do: String.trim_trailing(text, "/") == String.trim_trailing(value, "/"),
      else: text == value
  end

  ## --- multistatus verifiers --------------------------------------

  defp multistatus_status(conn), do: expect_status(conn, 207)

  defp expect_status(%{status: status}, status), do: :ok
  defp expect_status(conn, expected), do: {:failed, "status #{conn.status}, expected #{expected}"}

  # Each response is classified by its status the way the suite does:
  # a bare `DAV:status` of 2xx is ok, any propstat at all is ok, and
  # anything else is bad. Trailing slashes are stripped so that a
  # collection href compares equal either way.
  defp responses(conn) do
    case Xml.parse(conn.resp_body) do
      {:ok, document} -> {:ok, Enum.map(direct(document, "response"), &classify/1)}
      _unparseable -> {:failed, "not valid XML: #{inspect(String.slice(conn.resp_body, 0, 60))}"}
    end
  end

  defp classify(response) do
    href =
      case Enum.find(response.children, &local?(&1, "href")) do
        nil -> ""
        element -> element.text |> String.trim() |> URI.decode() |> String.trim_trailing("/")
      end

    propstats = Enum.filter(response.children, &local?(&1, "propstat"))

    {ok?, code} =
      case Enum.find(response.children, &local?(&1, "status")) do
        nil -> {propstats != [], 0}
        element -> status_of(element.text)
      end

    %{href: href, ok?: ok?, code: code, propstats: propstats}
  end

  defp status_of(text) do
    case String.trim(text) do
      "HTTP/1.1 " <> rest ->
        digits = String.slice(rest, 0, 3)
        {String.starts_with?(digits, "2"), String.to_integer(digits)}

      _other ->
        {false, 0}
    end
  end

  # `count` compares against the ok set less one — upstream counts the
  # collection itself among the responses and subtracts it.
  defp multistatus_items(args, responses, conn) do
    ok = for response <- responses, response.ok?, into: MapSet.new(), do: response.href
    bad = for response <- responses, not response.ok?, into: MapSet.new(), do: response.href

    case tallied(args, ok, bad) do
      nil -> matched(args, responses, ok, bad, conn)
      outcome -> outcome
    end
  end

  # The three counting forms, which answer without looking at any
  # href.
  defp tallied(args, ok, bad) do
    cond do
      counted = single(args, "count") -> compare(MapSet.size(ok) - 1, counted, "items")
      counted = single(args, "totalcount") -> compare(MapSet.size(ok), counted, "items")
      counted = single(args, "responsecount") -> responses(ok, bad, counted)
      true -> nil
    end
  end

  defp responses(ok, bad, counted) do
    compare(MapSet.size(ok) + MapSet.size(bad), counted, "responses")
  end

  defp matched(args, responses, ok, bad, conn) do
    cond do
      href_sets?(args) ->
        hrefs(args, ok, bad, conn)

      coded?(args) ->
        coded(args, responses, conn)

      args == %{} ->
        # "If no hrefs requested, then assume none should come back."
        responses(ok, bad, 0)

      true ->
        {:skipped, "multistatusItems form not implemented: #{inspect(Map.keys(args))}"}
    end
  end

  defp href_sets?(args), do: Enum.any?(~w(okhrefs badhrefs nohrefs), &Map.has_key?(args, &1))

  # An argument named by a number is the set of hrefs expected to come
  # back with that status. `<arg><name>424</name>…` is how a suite
  # checks that a request which failed for one member was refused for
  # the rest rather than half-applied.
  defp coded?(args), do: Enum.any?(Map.keys(args), &numeric?/1)

  defp numeric?(name), do: match?({_code, ""}, Integer.parse(name))

  # Unlike `okhrefs`, these are compared as written: upstream passes
  # only the href *sets* through its prefixing, never the ones keyed by
  # a status. It matters here, because what comes back beside a status
  # is commonly a calendar user address rather than a path.
  defp coded(args, responses, _conn) do
    expected =
      for {name, values} <- args, numeric?(name), into: %{} do
        {elem(Integer.parse(name), 0), MapSet.new(values, &String.trim_trailing(&1, "/"))}
      end

    returned =
      Enum.group_by(responses, & &1.code, & &1.href)
      |> Map.new(fn {code, hrefs} -> {code, MapSet.new(hrefs)} end)

    differing(expected, returned)
  end

  defp differing(expected, returned) do
    codes = Enum.sort(Enum.uniq(Map.keys(expected) ++ Map.keys(returned)))

    problems =
      for code <- codes,
          wanted = Map.get(expected, code, MapSet.new()),
          got = Map.get(returned, code, MapSet.new()),
          not MapSet.equal?(wanted, got) do
        "#{code}: expected #{inspect(MapSet.to_list(wanted))}, got #{inspect(MapSet.to_list(got))}"
      end

    if problems == [], do: :passed, else: {:failed, Enum.join(problems, "; ")}
  end

  defp hrefs(args, ok, bad, conn) do
    args = Map.new(args, fn {name, values} -> {name, unbracketed(values, conn)} end)
    prefix = prefix(args, conn)
    expected_ok = href_set(args, "okhrefs", prefix)
    expected_bad = href_set(args, "badhrefs", prefix)
    absent = href_set(args, "nohrefs", prefix)

    # `ignoremissing` reads backwards: upstream uses it to mean "hrefs
    # the expectation does not name are fine" — the named `okhrefs`
    # must still all be present, the extras are simply not counted
    # against the response.
    surplus? = not Map.has_key?(args, "ignoremissing")

    [
      {"missing (OK)", MapSet.difference(expected_ok, ok)},
      {"unexpected (OK)",
       if(surplus?, do: MapSet.difference(ok, expected_ok), else: MapSet.new())},
      {"missing (BAD)", MapSet.difference(expected_bad, bad)},
      {"unexpected (BAD)",
       if(surplus?, do: MapSet.difference(bad, expected_bad), else: MapSet.new())},
      {"present but should not be", MapSet.intersection(absent, MapSet.union(ok, bad))}
    ]
    |> Enum.reject(fn {_label, set} -> MapSet.size(set) == 0 end)
    |> case do
      [] ->
        :passed

      problems ->
        {:failed,
         Enum.map_join(problems, "; ", fn {l, s} -> "#{l}: #{inspect(Enum.take(s, 3))}" end)}
    end
  end

  # A bracketed value is a list — serverinfo's
  # `$calendar_sync_extra_items:` is `[-]`, and the home variant names
  # several items. Upstream's `processHrefSubstitutions` splits them
  # out, with `-` standing for the request URI itself.
  defp unbracketed(values, conn) do
    Enum.flat_map(values, &listed_hrefs(&1, conn))
  end

  defp listed_hrefs(value, conn) do
    if String.starts_with?(value, "[") and String.ends_with?(value, "]") do
      value
      |> String.slice(1..-2//1)
      |> String.split(",", trim: true)
      |> Enum.map(fn
        "-" -> conn.request_path
        item -> item
      end)
    else
      [value]
    end
  end

  # `src/utils.processHrefSubstitutions` is not vendored. From its use
  # here it makes a relative href absolute against the request URI, or
  # against an explicit `prefix` argument, where `-` means none.
  defp prefix(args, conn) do
    case single_value(args, "prefix") do
      nil -> conn.request_path
      "-" -> ""
      given -> given
    end
  end

  # Expected hrefs are *not* decoded. Upstream unquotes only what the
  # response carried, so a test naming `2%20a.ics` is comparing against
  # a response href that decoded to exactly that. Decoding both sides
  # turns one `%20` into a space and reports a correct server as
  # returning the wrong resource.
  defp href_set(args, name, prefix) do
    for href <- Map.get(args, name, []), into: MapSet.new() do
      href
      |> then(&if String.starts_with?(&1, "/"), do: &1, else: Path.join(prefix, &1))
      |> URI.decode()
      |> String.trim_trailing("/")
      # A scenario building `$grabbed:/name` around an href grabbed
      # with its trailing slash writes `//`; one path, one slash.
      |> String.replace(~r{/+}, "/")
    end
  end

  # Property values are compared as sets, so a test naming a property
  # without a value must ignore whatever value came back. Tests that
  # compare an *XML* value are skipped rather than guessed at: upstream
  # normalises both sides through ElementTree's serialiser, which this
  # cannot reproduce, and a wrong comparison is worse than none.
  defp propfind_items(args, responses) do
    ok_specs = specifications(args, "okprops")
    bad_specs = specifications(args, "badprops")

    responses =
      responses
      |> Enum.reject(&ignored?(&1, args))
      |> narrowed_to(args)

    case single(args, "count") do
      nil -> each(responses, &properties_match(&1, ok_specs, bad_specs))
      counted -> compare(length(responses), counted, "responses")
    end
  end

  # A test names the hrefs it is not asking about. The collection a
  # `Depth: 1` PROPFIND was made against is the usual one: it answers
  # for itself as well as its members, and it has none of the
  # properties the members are being checked for.
  defp ignored?(%{href: href}, args) do
    args
    |> Map.get("ignore", [])
    |> Enum.any?(&(String.trim_trailing(&1, "/") == href))
  end

  # The counterpart to `ignore`: a test that names the one href it
  # *is* asking about, and every other row in the multistatus is
  # somebody else's business.
  defp narrowed_to(responses, args) do
    case Map.get(args, "only") do
      nil ->
        responses

      onlys ->
        Enum.filter(responses, fn %{href: href} ->
          Enum.any?(onlys, &(String.trim_trailing(&1, "/") == href))
        end)
    end
  end

  # Stops at the first response that does not match, the way upstream
  # reports the first mismatching href.
  defp each(items, check) do
    Enum.reduce_while(items, :passed, fn item, _outcome ->
      case check.(item) do
        :passed -> {:cont, :passed}
        other -> {:halt, other}
      end
    end)
  end

  defp specifications(args, name) do
    for specification <- Map.get(args, name, []) do
      cond do
        String.contains?(specification, "$") ->
          [property, value] = String.split(specification, "$", parts: 2)
          {property, blank_to_nil(value)}

        String.contains?(specification, "!") ->
          [property, _value] = String.split(specification, "!", parts: 2)
          {property, :negated}

        true ->
          {specification, nil}
      end
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp properties_match(response, ok_specs, bad_specs) do
    {found_ok, found_bad} = collect(response)
    wanted_ok = MapSet.new(ok_specs, &elem(&1, 0))
    wanted_bad = MapSet.new(bad_specs, &elem(&1, 0))

    missing = MapSet.difference(wanted_ok, found_ok)
    extra = MapSet.difference(found_ok, wanted_ok)
    missing_bad = MapSet.difference(wanted_bad, found_bad)

    cond do
      MapSet.size(missing) > 0 ->
        {:failed, "not returned (OK): #{inspect(Enum.take(missing, 4))}"}

      MapSet.size(missing_bad) > 0 ->
        {:failed, "not returned (BAD): #{inspect(Enum.take(missing_bad, 4))}"}

      MapSet.size(extra) > 0 ->
        {:failed, "unexpected (OK): #{inspect(Enum.take(extra, 4))}"}

      true ->
        valued(response, ok_specs)
    end
  end

  # A specification may name a value as well as a property. Where that
  # value is itself XML, it is compared structurally — upstream
  # normalises both sides through ElementTree's serialiser, and
  # abstaining because that output cannot be reproduced left tests
  # unmeasured for a difference that does not matter.
  defp valued(response, specifications) do
    each(Enum.reject(specifications, &(elem(&1, 1) in [nil, :negated])), fn {name, expected} ->
      compare_value(name, expected, rendered(response, name))
    end)
  end

  defp compare_value(name, _expected, []), do: {:failed, "#{name} was not returned"}

  defp compare_value(name, expected, found) do
    if Enum.any?(found, &equivalent?(&1, expected)) do
      :passed
    else
      {:failed, "#{name} is #{inspect(hd(found))}, expected #{inspect(expected)}"}
    end
  end

  # Text compares as text; XML compares as structure.
  defp equivalent?(actual, expected) do
    if String.starts_with?(String.trim(expected), "<") do
      structurally_equal?(actual, expected)
    else
      String.trim(actual) == String.trim(expected)
    end
  end

  defp structurally_equal?(actual, expected) do
    with {:ok, left} <- Xml.parse(wrapped(actual)),
         {:ok, right} <- Xml.parse(wrapped(expected)) do
      same?(left, right)
    else
      _unparseable -> false
    end
  end

  # A property's value may be several sibling elements, which is not a
  # document until it has a root.
  defp wrapped(fragment) do
    ~s(<w xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav" xmlns:CS="http://calendarserver.org/ns/">) <>
      fragment <> "</w>"
  end

  # The property's content as written, so a structured value can be
  # compared against the document the test names.
  defp rendered(response, name) do
    for propstat <- response.propstats,
        prop <- Enum.filter(propstat.children, &local?(&1, "prop")),
        child <- prop.children,
        clark(child.name) == name,
        do: inner_xml(child)
  end

  defp inner_xml(%{children: [], text: text}), do: text

  defp inner_xml(%{children: children}), do: Enum.map_join(children, "", &element_xml/1)

  defp element_xml(%{name: {namespace, local}, attributes: attributes, children: [], text: ""}) do
    "<" <> qualified(namespace, local) <> rendered_attributes(attributes) <> "/>"
  end

  defp element_xml(%{name: {namespace, local}, attributes: attributes} = element) do
    tag = qualified(namespace, local)

    "<" <>
      tag <> rendered_attributes(attributes) <> ">" <> inner_xml(element) <> "</" <> tag <> ">"
  end

  defp qualified(namespace, local), do: (@prefixes[namespace] || "D") <> ":" <> local

  defp rendered_attributes(attributes) do
    Enum.map_join(attributes, "", fn {name, value} -> ~s( #{name}="#{value}") end)
  end

  # Names are compared in Clark notation — `{DAV:}getetag` — which is
  # how the scenarios write them.
  defp collect(response) do
    Enum.reduce(response.propstats, {MapSet.new(), MapSet.new()}, &add(&1, &2))
  end

  defp add(propstat, {ok, bad}) do
    names = MapSet.new(names_in(propstat))

    if ok?(propstat),
      do: {MapSet.union(ok, names), bad},
      else: {ok, MapSet.union(bad, names)}
  end

  defp ok?(propstat) do
    case Enum.find(propstat.children, &local?(&1, "status")) do
      nil -> false
      element -> element.text |> status_of() |> elem(0)
    end
  end

  defp names_in(propstat) do
    case Enum.find(propstat.children, &local?(&1, "prop")) do
      nil -> []
      prop -> for child <- prop.children, do: clark(child.name)
    end
  end

  defp clark({namespace, local}), do: "{" <> namespace <> "}" <> local

  # A count argument may carry several values — upstream sums them, so
  # `0` plus `$calendar_sync_extra_count:` is the total expected.
  defp single(args, name) do
    case Map.get(args, name, []) do
      [] ->
        nil

      values ->
        Enum.reduce_while(values, 0, &counted/2)
    end
  end

  defp counted(value, acc) do
    case summed(value) do
      {:ok, number} -> {:cont, acc + number}
      :error -> {:halt, nil}
    end
  end

  # A count may be arithmetic — `$homecount:+1` when a scenario grabs
  # how many collections a home held before it shared one and asserts
  # there is now one more, or `$homecount:-1` after an uninvite.
  # Upstream evaluates the expression with `eval`; only sums and
  # differences of integers appear, so only those are read here. The
  # whole string must be consumed, so an unsubstituted variable is
  # still refused rather than read as the first number in it.
  defp summed(value) do
    trimmed = String.replace(value, " ", "")
    terms = ~r/[+-]?\d+/ |> Regex.scan(trimmed) |> List.flatten()

    if terms != [] and Enum.join(terms) == trimmed,
      do: {:ok, Enum.reduce(terms, 0, &(String.to_integer(&1) + &2))},
      else: :error
  end

  defp single_value(args, name) do
    case Map.get(args, name, []) do
      [value] -> value
      _absent_or_many -> nil
    end
  end

  defp compare(actual, actual, _noun), do: :passed
  defp compare(actual, expected, noun), do: {:failed, "#{actual} #{noun}, expected #{expected}"}

  # Upstream reads `DAV:response` with `tree.findall`, which matches
  # the multistatus element's own children and stops there. The
  # difference shows up in `expand-property`, whose expanded property
  # values *contain* `DAV:response` elements: counting those as
  # top-level responses turns a correct answer into a surplus.
  defp direct(element, name), do: Enum.filter(element.children, &local?(&1, name))

  defp elements(element, name) do
    matching = Enum.filter(element.children, &local?(&1, name))
    matching ++ Enum.flat_map(element.children, &elements(&1, name))
  end

  defp local?(%{name: {_namespace, name}}, name), do: true
  defp local?(_element, _name), do: false

  defp detail(%{resp_body: body}) when is_binary(body) and body != "" do
    " — " <>
      String.slice(String.replace(body, ~r/<\?xml[^>]*\?>|xmlns:?[A-Za-z]*="[^"]*"/, ""), 0, 3000)
  end

  defp detail(_no_body), do: ""

  # "2xx" is any status in that class; a bare number is exact.
  defp status_matches?(<<digit::binary-1, "xx">>, status) do
    case Integer.parse(digit) do
      {class, ""} -> div(status, 100) == class
      _unreadable -> false
    end
  end

  defp status_matches?(expected, status) do
    case Integer.parse(expected) do
      {value, ""} -> status == value
      _unreadable -> false
    end
  end

  # A specification is a header name, optionally prefixed and
  # optionally carrying a value test:
  #
  #     DAV            present exactly once
  #     !DAV           absent
  #     *DAV           present, any number of times
  #     DAV$1, 2       present, and matching the pattern after `$`
  #     DAV!2          present, and *not* matching the pattern after `!`
  #
  defp header_matches(specification, conn) do
    {presence, rest} = presence(specification)
    {name, pattern, wanted?} = value_test(rest)
    values = Conn.get_resp_header(conn, String.downcase(name))

    case present(values, presence, name) do
      :passed -> valued(values, pattern, wanted?, name)
      other -> other
    end
  end

  defp present([], :none, _name), do: :passed
  defp present([], _presence, name), do: {:failed, "missing response header #{name}"}
  defp present(_values, :none, name), do: {:failed, "header #{name} present, expected absent"}

  defp present(values, :single, name) when length(values) != 1,
    do: {:failed, "multiple #{name} headers"}

  defp present(_values, _presence, _name), do: :passed

  defp valued(_values, nil, _wanted?, _name), do: :passed

  defp valued(values, pattern, wanted?, name) do
    if matches?(values, pattern) == wanted? do
      :passed
    else
      {:failed, "header #{name}: #{inspect(values)} against #{inspect(pattern)}"}
    end
  end

  defp presence("!" <> rest), do: {:none, rest}
  defp presence("*" <> rest), do: {:multiple, rest}
  defp presence(specification), do: {:single, specification}

  defp value_test(specification) do
    cond do
      String.contains?(specification, "$") ->
        [name, pattern] = String.split(specification, "$", parts: 2)
        {name, pattern, true}

      String.contains?(specification, "!") ->
        [name, pattern] = String.split(specification, "!", parts: 2)
        {name, pattern, false}

      true ->
        {specification, nil, true}
    end
  end

  # Spaces are stripped from both sides before matching, and the
  # pattern is anchored at the start only — `re.match`, not
  # `re.fullmatch`.
  defp matches?(values, pattern) do
    stripped = String.replace(pattern, " ", "")

    case Regex.compile("^" <> stripped) do
      {:ok, regex} -> Enum.any?(values, &Regex.match?(regex, String.replace(&1, " ", "")))
      _uncompilable -> Enum.any?(values, &(String.replace(&1, " ", "") == stripped))
    end
  end

  defp json_typed(conn) do
    type =
      conn |> Conn.get_resp_header("content-type") |> List.first("") |> String.split(";") |> hd()

    if type == "application/json" or String.ends_with?(type, "+json"),
      do: :ok,
      else: {:failed, "content-type #{type}"}
  end

  defp decoded(""), do: {:failed, "no response body"}

  defp decoded(body) do
    {:ok, :json.decode(body)}
  rescue
    _malformed -> {:failed, "response body is not JSON"}
  end

  # The pointer syntax is upstream's, extended twice: a `.` segment
  # stands for any member or item, and a trailing `~$value` asserts
  # that the value is among those the pointer reached. A pointer that
  # reaches nothing fails, which is what makes `exists` a test rather
  # than a description.
  defp json_pointers(document, args) do
    absent =
      for pointer <- Map.get(args, "exists", []),
          {path, expected} = split_pointer(pointer),
          reached = json_match(document, path),
          reached == [] or (expected != nil and expected not in Enum.map(reached, &written/1)),
          do: pointer

    present =
      for pointer <- Map.get(args, "notexists", []),
          {path, _expected} = split_pointer(pointer),
          json_match(document, path) != [],
          do: pointer

    case {absent, present} do
      {[], []} -> :passed
      {[], found} -> {:failed, "present in JSON: #{Enum.join(found, ", ")}"}
      {missing, _found} -> {:failed, "not in JSON: #{Enum.join(missing, ", ")}"}
    end
  end

  defp split_pointer(pointer) do
    case String.split(pointer, "~$", parts: 2) do
      [path] -> {path, nil}
      [path, expected] -> {path, expected}
    end
  end

  defp json_match(document, path) do
    path
    |> String.split("/", trim: true)
    |> Enum.reduce([document], fn segment, reached ->
      Enum.flat_map(reached, &json_step(&1, segment))
    end)
  end

  defp json_step(reached, ".") when is_list(reached), do: reached
  defp json_step(reached, ".") when is_map(reached), do: Map.values(reached)
  defp json_step(reached, key) when is_map(reached), do: reached |> Map.fetch(key) |> found()
  defp json_step(_reached, _segment), do: []

  defp found({:ok, value}), do: [value]
  defp found(:error), do: []

  defp written(value) when is_binary(value), do: value
  defp written(value), do: to_string(value)
end
