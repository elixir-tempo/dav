defmodule Dav.Xml do
  @moduledoc """
  The namespaced XML every DAV exchange is made of.

  Two jobs, and they are not symmetrical. **Building** responses must
  be exact, because clients parse them strictly and a missing namespace
  declaration is indistinguishable from a broken server. **Parsing**
  requests must be forgiving, because clients send unexpected elements,
  choose their own prefixes, and occasionally send bodies no
  specification describes.

  ### Qualified names

  A DAV property is identified by namespace *and* local name, never by
  prefix — `D:getetag` and `x:getetag` are the same property if both
  prefixes are bound to `DAV:`. Everything here works in `{namespace,
  local}` tuples for that reason, and prefixes exist only at the edges
  where XML is read or written.

  The WebDAV namespace is the string `DAV:`, colon included. It is not
  a URL and never was.

  """

  @dav "DAV:"
  @caldav "urn:ietf:params:xml:ns:caldav"
  @carddav "urn:ietf:params:xml:ns:carddav"

  @typedoc "A property or element name: its namespace and local part."
  @type qname :: {namespace :: String.t(), local :: String.t()}

  @typedoc """
  What a property is worth.

  A binary is text content. The structured forms exist so that the
  builder can see which namespaces a value uses and declare them —
  a value carrying `<C:calendar/>` in a prefix nobody bound produces a
  document strict clients reject, and that failure is invisible until
  a real client refuses to sync.

  * `{:names, qnames}` renders each as an empty element, which is what
    `DAV:resourcetype` and most flag-like values are.

  * `{:report_set, qnames}` is `DAV:supported-report-set`, whose
    nesting the specification fixes.

  * `{:hrefs, urls}` renders each as a `DAV:href`, which is how every
    property that points at another resource is written —
    `CALDAV:calendar-home-set`, `CALDAV:schedule-inbox-URL` and their
    kind. A bare string there would be read as text, and a client
    looking for an `href` child would find none.

  * `{:elements, namespaces, iodata}` is the escape hatch for content
    this module cannot construct. The namespaces used **must** be
    listed, because that is the only way they get declared.
  """
  @type value ::
          String.t()
          | {:names, [qname()]}
          | {:report_set, [qname()]}
          | {:hrefs, [String.t()]}
          | {:elements, [String.t()], iodata()}
          | nil

  @doc """
  The WebDAV namespace, `DAV:`.

  ### Returns

  * The namespace string.

  ### Examples

      iex> Dav.Xml.dav()
      "DAV:"

  """
  @spec dav() :: String.t()
  def dav, do: @dav

  @doc """
  The CalDAV namespace.

  ### Returns

  * The namespace string.

  ### Examples

      iex> Dav.Xml.caldav()
      "urn:ietf:params:xml:ns:caldav"

  """
  @spec caldav() :: String.t()
  def caldav, do: @caldav

  @doc """
  The CardDAV namespace.

  ### Returns

  * The namespace string.

  ### Examples

      iex> Dav.Xml.carddav()
      "urn:ietf:params:xml:ns:carddav"

  """
  @spec carddav() :: String.t()
  def carddav, do: @carddav

  @doc """
  Escape text for an XML body.

  ### Arguments

  * `text` is any binary.

  ### Returns

  * The binary with `&`, `<`, `>`, `"` and `'` replaced by entities.

  ### Examples

      iex> Dav.Xml.escape(~s(a & b < c))
      "a &amp; b &lt; c"

  """
  @spec escape(String.t()) :: String.t()
  def escape(text) when is_binary(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  @doc """
  Build a `207 Multi-Status` body.

  The shape every `PROPFIND` and most `REPORT`s answer with: one
  `response` per resource, and within it one `propstat` per distinct
  status, because a single request routinely asks for properties that
  partly exist.

  Namespaces are collected from every name used and declared once on
  the root element, with generated prefixes. Clients must not be
  assumed to care which prefix is used — only that it is bound.

  ### Arguments

  * `responses` is a list of `{href, propstats}`, where `propstats` is
    a list of `{status, properties}` and each property is a
    `{t:qname/0, t:value/0}` pair. A `nil` value writes an empty
    element, which is how a `404` propstat names what was missing.

  ### Returns

  * The XML document as `t:iodata/0`.

  ### Examples

      iex> Dav.Xml.multistatus([
      ...>   {"/calendars/", [{"HTTP/1.1 200 OK", [{{"DAV:", "displayname"}, "Calendars"}]}]}
      ...> ])
      ...> |> IO.iodata_to_binary()
      ...> |> String.contains?("<D:displayname>Calendars</D:displayname>")
      true

  """
  @spec multistatus([{String.t(), [{String.t(), [{qname(), value()}]}]}]) :: iolist()
  def multistatus(responses) when is_list(responses) do
    prefixes = prefixes(responses)

    declarations =
      Enum.map(prefixes, fn {namespace, prefix} ->
        [" xmlns:", prefix, "=\"", escape(namespace), "\""]
      end)

    root = prefixes[@dav]

    [
      ~s(<?xml version="1.0" encoding="utf-8"?>),
      "<",
      root,
      ":multistatus",
      declarations,
      ">",
      Enum.map(responses, &response(&1, prefixes, root)),
      "</",
      root,
      ":multistatus>"
    ]
  end

  # A response is normally one or more propstats, but a resource that
  # could not be read at all carries a bare status instead — there are
  # no properties to report a status *for*. `calendar-multiget` needs
  # this: it must answer for every href it was given, including the
  # ones that are not there.
  defp response({href, {:status, status}}, _prefixes, root) do
    [
      "<",
      root,
      ":response>",
      "<",
      root,
      ":href>",
      escape(href),
      "</",
      root,
      ":href>",
      "<",
      root,
      ":status>",
      escape(status),
      "</",
      root,
      ":status>",
      "</",
      root,
      ":response>"
    ]
  end

  defp response({href, propstats}, prefixes, root) do
    [
      "<",
      root,
      ":response>",
      "<",
      root,
      ":href>",
      escape(href),
      "</",
      root,
      ":href>",
      Enum.map(propstats, &propstat(&1, prefixes, root)),
      "</",
      root,
      ":response>"
    ]
  end

  defp propstat({status, properties}, prefixes, root) do
    [
      "<",
      root,
      ":propstat>",
      "<",
      root,
      ":prop>",
      Enum.map(properties, &property(&1, prefixes)),
      "</",
      root,
      ":prop>",
      "<",
      root,
      ":status>",
      escape(status),
      "</",
      root,
      ":status>",
      "</",
      root,
      ":propstat>"
    ]
  end

  defp property({{namespace, local}, value}, prefixes) do
    tag = [prefixes[namespace], ":", local]

    case value do
      nil ->
        ["<", tag, "/>"]

      {:names, names} ->
        ["<", tag, ">", Enum.map(names, &empty(&1, prefixes)), "</", tag, ">"]

      {:report_set, names} ->
        ["<", tag, ">", Enum.map(names, &report(&1, prefixes)), "</", tag, ">"]

      {:hrefs, hrefs} ->
        ["<", tag, ">", Enum.map(hrefs, &href(&1, prefixes)), "</", tag, ">"]

      {:elements, _namespaces, inner} ->
        ["<", tag, ">", inner, "</", tag, ">"]

      text when is_binary(text) ->
        ["<", tag, ">", escape(text), "</", tag, ">"]
    end
  end

  # Namespaces a structured value will use, so they are declared
  # alongside the ones the property names contribute. Without this a
  # value carrying `<C:calendar/>` emits an unbound prefix, which is
  # malformed XML that only fails at a real client.
  defp within({:names, names}), do: for({namespace, _local} <- names, do: namespace)
  defp within({:report_set, names}), do: for({namespace, _local} <- names, do: namespace)
  defp within({:hrefs, _hrefs}), do: [dav()]
  defp within({:elements, namespaces, _inner}), do: namespaces
  defp within(_other), do: []

  defp empty({namespace, local}, prefixes), do: ["<", prefixes[namespace], ":", local, "/>"]

  defp href(value, prefixes) do
    tag = [prefixes[dav()], ":href"]

    ["<", tag, ">", escape(value), "</", tag, ">"]
  end

  defp report(name, prefixes) do
    ["<D:supported-report><D:report>", empty(name, prefixes), "</D:report></D:supported-report>"]
  end

  # `DAV:` always takes the first prefix so the common case reads the
  # way every other server's output does; anything else is numbered.
  defp prefixes(responses) do
    used =
      for {_href, propstats} <- responses,
          is_list(propstats),
          {_status, properties} <- propstats,
          {{namespace, _local}, value} <- properties,
          candidate <- [namespace | within(value)],
          do: candidate

    others = used |> Enum.uniq() |> Enum.reject(&(&1 == @dav)) |> Enum.sort()

    known = %{@caldav => "C", @carddav => "CARD"}

    {map, _next} =
      Enum.reduce(others, {%{@dav => "D"}, 0}, fn namespace, {acc, next} ->
        case known[namespace] do
          nil -> {Map.put(acc, namespace, "n#{next}"), next + 1}
          prefix -> {Map.put(acc, namespace, prefix), next}
        end
      end)

    map
  end

  @doc """
  Read a `PROPFIND` request body.

  Three forms are permitted, and a client may legitimately send no body
  at all — which means the same as `DAV:allprop` and is what several
  clients do.

  Parsing is deliberately forgiving about everything except the shape:
  unknown elements are ignored rather than refused, because a client
  that asks for a property this server has never heard of is asking a
  reasonable question and deserves a `404` for that property, not a
  `400` for the request.

  ### Arguments

  * `body` is the raw request body, which may be empty.

  ### Returns

  * `{:ok, :allprop}` — every property the server cares to report; or

  * `{:ok, :propname}` — the *names* of properties, without values; or

  * `{:ok, {:prop, names}}` — the named properties, as `t:qname/0`s; or

  * `{:error, :malformed}` when the body is not XML, or is XML that is
    not a `propfind`.

  ### Examples

      iex> Dav.Xml.parse_propfind("")
      {:ok, :allprop}

      iex> Dav.Xml.parse_propfind(~s(<?xml version="1.0"?><D:propfind xmlns:D="DAV:"><D:allprop/></D:propfind>))
      {:ok, :allprop}

      iex> Dav.Xml.parse_propfind(~s(<?xml version="1.0"?><D:propfind xmlns:D="DAV:"><D:prop><D:getetag/></D:prop></D:propfind>))
      {:ok, {:prop, [{"DAV:", "getetag"}]}}

      iex> Dav.Xml.parse_propfind("not xml at all")
      {:error, :malformed}

  """
  @spec parse_propfind(binary()) ::
          {:ok, :allprop | :propname | {:prop, [qname()]}} | {:error, :malformed}
  def parse_propfind(body) when is_binary(body) do
    case String.trim(body) do
      "" -> {:ok, :allprop}
      trimmed -> propfind(trimmed)
    end
  end

  defp propfind(body) do
    case scan(body) do
      {:ok, document} ->
        cond do
          child?(document, "allprop") -> {:ok, :allprop}
          child?(document, "propname") -> {:ok, :propname}
          true -> {:ok, {:prop, requested(document)}}
        end

      {:error, :malformed} = error ->
        error
    end
  end

  # Two things here are load-bearing.
  #
  # `allow_entities: false` is passed rather than assumed. OTP 29
  # refuses external entities by default, but the default has changed
  # before and enabling them demonstrably reads local files into the
  # document — which is a request body from an unauthenticated client.
  #
  # The body goes in as **bytes**, not codepoints. xmerl decodes
  # according to the document's own declaration, so handing it
  # `String.to_charlist/1` presents `é` as character 233 and the whole
  # document is refused as containing an illegal character. Any
  # accented summary or non-Latin name would make an otherwise valid
  # request malformed.
  defp scan(body) do
    {document, _rest} =
      :xmerl_scan.string(:binary.bin_to_list(body),
        allow_entities: false,
        quiet: true
      )

    {:ok, document}
  rescue
    _malformed -> {:error, :malformed}
  catch
    _kind, _value -> {:error, :malformed}
  end

  defp child?(element, local) do
    element |> children_of() |> Enum.any?(&(local_name(&1) == local))
  end

  defp requested(document) do
    case find_prop(document) do
      nil ->
        []

      element ->
        element |> children_of() |> Enum.flat_map(&qname/1) |> Enum.uniq()
    end
  end

  defp find_prop({:xmlElement, _n, _e, _nsi, _ns, _p, _pos, _a, content, _l, _pa, _t} = element) do
    if local_name(element) == "prop" do
      element
    else
      Enum.find_value(content, &find_prop/1)
    end
  end

  defp find_prop(_other), do: nil

  defp qname({:xmlElement, _n, _e, _nsi, _ns, _p, _pos, _a, _c, _l, _pa, _t} = element) do
    [element_qname(element)]
  end

  defp qname(_other), do: []

  # A name may be prefixed — `C:filter` with `xmlns:C` — or unprefixed
  # under a default namespace: `<filter>` inside
  # `<calendar-query xmlns="urn:ietf:params:xml:ns:caldav">`. Both are
  # ordinary, both appear in real client requests, and reading only
  # the first form drops the second silently rather than failing
  # loudly, which is how it survives a test suite written by hand.
  defp element_qname({:xmlElement, name, _e, nsinfo, namespace, _p, _pos, _a, _c, _l, _pa, _t}) do
    case nsinfo do
      {prefix, local} -> {uri_for(namespace, prefix), List.to_string(local)}
      _unprefixed -> {default_uri(namespace), Atom.to_string(name)}
    end
  end

  # Whitespace between elements is a node too, and asking it for a
  # name must be answered rather than crash — an empty name matches
  # nothing, which is the right outcome.
  defp element_qname(_not_an_element), do: {"", ""}

  defp default_uri({:xmlNamespace, default, _nodes}), do: text(default)
  defp default_uri(_other), do: ""

  defp local_name(element), do: element |> element_qname() |> elem(1)

  defp children_of({:xmlElement, _n, _e, _nsi, _ns, _p, _pos, _a, content, _l, _pa, _t}),
    do: content

  defp children_of(_other), do: []

  defp uri_for({:xmlNamespace, _default, nodes}, prefix) do
    case List.keyfind(nodes, prefix, 0) do
      {_prefix, uri} -> text(uri)
      nil -> ""
    end
  end

  defp uri_for(_namespace, _prefix), do: ""

  # xmerl reports a namespace URI as an atom, a charlist or a binary
  # depending on where it came from. All three mean the same string.
  defp text(value) when is_atom(value), do: Atom.to_string(value)
  defp text(value) when is_binary(value), do: value
  defp text(value) when is_list(value), do: List.to_string(value)

  @doc """
  The name of the report a `REPORT` body asks for.

  `REPORT` is extensible by design: the method itself says nothing
  about what is wanted, and the root element of the body names it. That
  is the mechanism CalDAV and CardDAV extend WebDAV through, and it is
  why the method belongs in the base rather than in either of them.

  ### Arguments

  * `body` is the raw request body.

  ### Returns

  * `{:ok, qname}` naming the report; or

  * `{:error, :malformed}` when the body is not XML, or is empty — a
    `REPORT` without a body asks for nothing.

  ### Examples

      iex> Dav.Xml.report_name(~s(<?xml version="1.0"?><D:sync-collection xmlns:D="DAV:"/>))
      {:ok, {"DAV:", "sync-collection"}}

      iex> Dav.Xml.report_name(~s(<C:calendar-query xmlns:C="urn:ietf:params:xml:ns:caldav"/>))
      {:ok, {"urn:ietf:params:xml:ns:caldav", "calendar-query"}}

      iex> Dav.Xml.report_name("")
      {:error, :malformed}

  """
  @spec report_name(binary()) :: {:ok, qname()} | {:error, :malformed}
  def report_name(body) when is_binary(body) do
    body |> String.trim() |> named()
  end

  defp named(""), do: {:error, :malformed}

  defp named(body) do
    with {:ok, document} <- scan(body) do
      root(qname(document))
    end
  end

  defp root([name]), do: {:ok, name}
  defp root(_nothing), do: {:error, :malformed}

  @doc """
  A `DAV:error` document naming a precondition that failed.

  RFC 4918 gives errors a body of their own so a client learns *which*
  rule it broke rather than only that something was refused. A `403`
  with `DAV:supported-report` inside is a different instruction from a
  bare `403`: it says the request was well-formed and this resource
  does not offer that report.

  ### Arguments

  * `condition` is the precondition's `t:qname/0`.

  ### Returns

  * The XML document as `t:iolist/0`.

  ### Examples

      iex> Dav.Xml.error({"DAV:", "supported-report"}) |> IO.iodata_to_binary()
      ~s(<?xml version="1.0" encoding="utf-8"?><D:error xmlns:D="DAV:"><D:supported-report/></D:error>)

  """
  @spec error(qname()) :: iolist()
  def error({namespace, local}) do
    {prefix, declaration} =
      if namespace == @dav do
        {"D", [~s( xmlns:D="), @dav, ~s(")]}
      else
        {"E", [~s( xmlns:D="), @dav, ~s(" xmlns:E="), escape(namespace), ~s(")]}
      end

    [
      ~s(<?xml version="1.0" encoding="utf-8"?>),
      "<D:error",
      declaration,
      "><",
      prefix,
      ":",
      local,
      "/></D:error>"
    ]
  end

  @doc """
  A `DAV:supported-report-set` value from a list of report names.

  The nesting is the specification's, and it is deeper than it looks:
  a set contains `supported-report` elements, each of which contains a
  `report` element, which contains the report's own element.

  ### Arguments

  * `names` is a list of report `t:qname/0`s.

  ### Returns

  * A `t:value/0` ready to be given to `multistatus/1`.

  ### Examples

      iex> Dav.Xml.supported_report_set([{"DAV:", "sync-collection"}])
      {:report_set, [{"DAV:", "sync-collection"}]}

  """
  @spec supported_report_set([qname()]) :: value()
  def supported_report_set(names) when is_list(names), do: {:report_set, names}

  @doc """
  Read a `PROPPATCH` request body.

  Instructions come back **in document order**, which RFC 4918 calls
  out as an explicit exception to XML's usual indifference to
  ordering: a client may set a property and then remove it, and the
  result depends on which came first.

  ### Limits

  A `set` value is captured as its text content. A dead property whose
  value is structured XML round-trips as the text inside it, which is
  wrong for clients that store markup — and is recorded here rather
  than discovered later.

  ### Arguments

  * `body` is the raw request body.

  ### Returns

  * `{:ok, instructions}` where each is `{:set, qname, value}` or
    `{:remove, qname}`, in document order; or

  * `{:error, :malformed}` when the body is not a `propertyupdate`.

  ### Examples

      iex> body = ~s(<?xml version="1.0"?><D:propertyupdate xmlns:D="DAV:"><D:set><D:prop><D:displayname>Kim</D:displayname></D:prop></D:set></D:propertyupdate>)
      iex> Dav.Xml.parse_proppatch(body)
      {:ok, [{:set, {"DAV:", "displayname"}, "Kim"}]}

      iex> body = ~s(<?xml version="1.0"?><D:propertyupdate xmlns:D="DAV:"><D:remove><D:prop><D:displayname/></D:prop></D:remove></D:propertyupdate>)
      iex> Dav.Xml.parse_proppatch(body)
      {:ok, [{:remove, {"DAV:", "displayname"}}]}

      iex> Dav.Xml.parse_proppatch(~s(<D:propfind xmlns:D="DAV:"/>))
      {:error, :malformed}

  """
  @spec parse_proppatch(binary()) ::
          {:ok, [{:set, qname(), String.t()} | {:remove, qname()}]} | {:error, :malformed}
  def parse_proppatch(body) when is_binary(body) do
    with {:ok, document} <- scan(String.trim(body)) do
      update(document)
    end
  end

  defp update({:xmlElement, _n, _e, _nsi, _ns, _p, _pos, _a, content, _l, _pa, _t} = element) do
    if local_name(element) == "propertyupdate" do
      {:ok, Enum.flat_map(content, &instructions/1)}
    else
      {:error, :malformed}
    end
  end

  defp update(_other), do: {:error, :malformed}

  # `set` and `remove` are read in the order they appear, and so are
  # the properties inside each.
  defp instructions(
         {:xmlElement, _n, _e, _nsi, _ns, _p, _pos, _a, content, _l, _pa, _t} = element
       ) do
    verb = local_name(element)

    if verb in ["set", "remove"], do: read_instructions(verb, content), else: []
  end

  defp instructions(_other), do: []

  defp read_instructions(verb, content) do
    kind = if verb == "set", do: :set, else: :remove

    content
    |> Enum.flat_map(&properties_of/1)
    |> Enum.map(fn {name, value} ->
      if kind == :set, do: {:set, name, value}, else: {:remove, name}
    end)
  end

  defp properties_of(
         {:xmlElement, _n, _e, _nsi, _ns, _p, _pos, _a, content, _l, _pa, _t} = element
       ) do
    if local_name(element) == "prop", do: Enum.flat_map(content, &named_value/1), else: []
  end

  defp properties_of(_other), do: []

  defp named_value({:xmlElement, _n, _e, _nsi, _ns, _p, _pos, _a, content, _l, _pa, _t} = element) do
    [{element_qname(element), text_of(content)}]
  end

  defp named_value(_other), do: []

  defp text_of(content) do
    Enum.map_join(content, fn
      {:xmlText, _parents, _pos, _lang, value, _type} -> List.to_string(value)
      _other -> ""
    end)
  end

  @typedoc """
  A parsed element, free of the parser's own representation.

  Extensions build on this rather than on xmerl records, so that
  `Dav.Cal` and `Dav.Card` never import a parser and the choice of one
  stays a private matter for this module.
  """
  @type element :: %{
          name: qname(),
          attributes: %{optional(String.t()) => String.t()},
          children: [element()],
          text: String.t()
        }

  @doc """
  Parse a document into a neutral element tree.

  ### Arguments

  * `body` is the raw request body.

  ### Returns

  * `{:ok, element}` for the root element; or

  * `{:error, :malformed}`.

  ### Examples

      iex> {:ok, root} = Dav.Xml.parse(~s(<C:filter xmlns:C="urn:ietf:params:xml:ns:caldav"><C:comp-filter name="VEVENT"/></C:filter>))
      iex> root.name
      {"urn:ietf:params:xml:ns:caldav", "filter"}
      iex> [child] = root.children
      iex> {child.name, child.attributes}
      {{"urn:ietf:params:xml:ns:caldav", "comp-filter"}, %{"name" => "VEVENT"}}

      iex> Dav.Xml.parse("not xml")
      {:error, :malformed}

  """
  @spec parse(binary()) :: {:ok, element()} | {:error, :malformed}
  def parse(body) when is_binary(body) do
    with {:ok, document} <- scan(String.trim(body)) do
      case tree(document) do
        [root] -> {:ok, root}
        _none -> {:error, :malformed}
      end
    end
  end

  defp tree(
         {:xmlElement, _n, _e, _nsi, _ns, _p, _pos, attributes, content, _l, _pa, _t} = element
       ) do
    [
      %{
        name: element_qname(element),
        attributes: Map.new(attributes, &attribute/1),
        children: Enum.flat_map(content, &tree/1),
        text: text_of(content)
      }
    ]
  end

  defp tree(_other), do: []

  defp attribute({:xmlAttribute, name, _e, _nsi, _ns, _p, _pos, _l, value, _norm}) do
    {Atom.to_string(name), text(value)}
  end
end
