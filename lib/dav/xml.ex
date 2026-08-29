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
  What a property is worth. A binary is text content; `{:elements,
  iodata}` is already-serialised child elements, which is how
  structured values like `DAV:resourcetype` are given.
  """
  @type value :: String.t() | {:elements, iodata()} | nil

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
      nil -> ["<", tag, "/>"]
      {:elements, inner} -> ["<", tag, ">", inner, "</", tag, ">"]
      text when is_binary(text) -> ["<", tag, ">", escape(text), "</", tag, ">"]
    end
  end

  # `DAV:` always takes the first prefix so the common case reads the
  # way every other server's output does; anything else is numbered.
  defp prefixes(responses) do
    used =
      for {_href, propstats} <- responses,
          {_status, properties} <- propstats,
          {{namespace, _local}, _value} <- properties,
          do: namespace

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

  # `allow_entities: false` is passed rather than assumed. OTP 29
  # refuses external entities by default, but the default has changed
  # before and enabling them demonstrably reads local files into the
  # document — which is a request body from an unauthenticated client.
  defp scan(body) do
    {document, _rest} =
      :xmerl_scan.string(String.to_charlist(body),
        allow_entities: false,
        quiet: true
      )

    {:ok, document}
  rescue
    _malformed -> {:error, :malformed}
  catch
    _kind, _value -> {:error, :malformed}
  end

  defp child?({:xmlElement, _n, _e, _nsi, _ns, _p, _pos, _a, content, _l, _pa, _t}, local) do
    Enum.any?(content, fn
      {:xmlElement, _n, _e, {_prefix, name}, _ns, _p, _pos, _a, _c, _l, _pa, _t} ->
        List.to_string(name) == local

      _other ->
        false
    end)
  end

  defp child?(_other, _local), do: false

  # The names asked for are the *children of* `DAV:prop`, not every
  # element in the document — the request element itself is not a
  # property, and neither is anything a client wraps around it.
  defp requested(document) do
    case find_prop(document) do
      nil ->
        []

      {:xmlElement, _n, _e, _ns, _nsi, _p, _pos, _a, content, _l, _pa, _t} ->
        content |> Enum.flat_map(&qname/1) |> Enum.uniq()
    end
  end

  defp find_prop({:xmlElement, _n, _e, nsinfo, _ns, _p, _pos, _a, content, _l, _pa, _t} = element) do
    case nsinfo do
      {_prefix, ~c"prop"} -> element
      _other -> Enum.find_value(content, &find_prop/1)
    end
  end

  defp find_prop(_other), do: nil

  defp qname({:xmlElement, _n, _e, {prefix, local}, namespace, _p, _pos, _a, _c, _l, _pa, _t}) do
    [{uri_for(namespace, prefix), List.to_string(local)}]
  end

  defp qname(_other), do: []

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
end
