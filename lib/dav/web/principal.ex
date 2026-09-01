defmodule Dav.Web.Principal do
  @moduledoc """
  The principal reports of RFC 3744 and RFC 3253.

  A client that has just authenticated knows almost nothing: not its
  own principal URL, not where its calendars live, not who else it may
  invite. These reports are how it finds out, and between them they
  are the whole of "discovery" in the DAV family.

  * `DAV:principal-match` — which principals match the current user,
    or which resources here are owned by them.

  * `DAV:principal-property-search` — find principals whose properties
    match a string. This is the address-book lookup behind every
    "invite someone" field in a calendar client.

  * `DAV:principal-search-property-set` — which properties may be
    searched, so a client can offer them rather than guess.

  * `DAV:expand-property` — follow the hrefs in a property and return
    the referenced resources' properties inline, saving a round trip
    per reference.

  Each is registered with `Dav.Web.Plug` like any other report.

  """

  alias Dav.Web.Acl
  alias Dav.Web.Properties
  alias Dav.Web.Resource
  alias Dav.Web.Store
  alias Dav.Xml

  defmodule AclPrincipalPropSet do
    @moduledoc """
    `DAV:acl-principal-prop-set` — RFC 3744 section 9.2.

    The properties of every principal named in a resource's ACL. Its
    stated purpose is turning an access control list into something a
    person can read: an ACL is a list of URLs, and this is how a client
    turns them into names to show beside each entry.

    Support for it is REQUIRED, and a principal appearing twice in the
    ACL is returned once.
    """

    @behaviour Dav.Web.Report

    alias Dav.Web.Principal

    @impl Dav.Web.Report
    def run(resource, body, depth, options)

    # "The request MUST include a Depth: 0 header."
    def run(%Resource{}, _body, depth, _options) when depth != 0, do: {:error, :malformed}

    def run(%Resource{} = resource, body, _depth, options) do
      with {:ok, document} <- Xml.parse(body) do
        wanted = Principal.requested(document)

        {:ok,
         resource
         |> Principal.acl_principals()
         |> Enum.uniq()
         |> Enum.flat_map(&Principal.resolved(&1, options))
         |> Enum.map(&Principal.response(&1, wanted))}
      end
    end
  end

  defmodule Match do
    @moduledoc """
    `DAV:principal-match` — RFC 3744 section 9.3.

    Answers "which of these resources are mine": either the principals
    that are the current user, or the resources here whose named
    property points at them.
    """

    @behaviour Dav.Web.Report

    alias Dav.Web.Principal

    @impl Dav.Web.Report
    def run(%Resource{} = collection, body, _depth, options) do
      with {:ok, document} <- Xml.parse(body) do
        wanted = Principal.requested(document)

        # A principal's own sub-principals — its proxy groups — count
        # among "the principals in the collection", one level down.
        surface = Principal.members(collection, options)

        nested = Enum.flat_map(surface, &Principal.sub_principals(&1, collection, options))

        {:ok,
         (surface ++ nested)
         |> Enum.uniq_by(& &1.path)
         |> Enum.filter(&Principal.mine?(&1, document, options))
         |> Enum.map(&Principal.response(&1, wanted))}
      end
    end
  end

  defmodule PropertySearch do
    @moduledoc """
    `DAV:principal-property-search` — RFC 3744 section 9.4.

    The lookup behind a client's "invite someone" field: find the
    principals whose `DAV:displayname`, or calendar user address, or
    any other searchable property, contains what was typed.
    """

    @behaviour Dav.Web.Report

    alias Dav.Web.Principal

    @impl Dav.Web.Report
    def run(%Resource{} = collection, body, _depth, options) do
      with {:ok, document} <- Xml.parse(body) do
        searches = Principal.searches(document)
        wanted = Principal.requested(document)

        {:ok,
         collection
         |> Principal.members(options)
         |> Enum.filter(&(Acl.principal?(&1) and Principal.matches?(&1, searches)))
         |> Enum.map(&Principal.response(&1, wanted))}
      end
    end
  end

  defmodule SearchPropertySet do
    @moduledoc """
    `DAV:principal-search-property-set` — RFC 3744 section 9.5.

    Which properties `DAV:principal-property-search` will search. A
    client that cannot ask this has to hard-code a guess.
    """

    @behaviour Dav.Web.Report

    alias Dav.Web.Principal

    @impl Dav.Web.Report
    def run(%Resource{}, _body, _depth, _options) do
      {:ok, {:body, "application/xml", Principal.search_property_set()}}
    end
  end

  defmodule ExpandProperty do
    @moduledoc """
    `DAV:expand-property` — RFC 3253 section 3.8.

    Follows the hrefs in a property and returns the referenced
    resources' properties inline. A client asking for a calendar home
    and its display name otherwise needs two round trips; over a
    mobile connection, for every principal in a list, that is the
    difference between usable and not.
    """

    @behaviour Dav.Web.Report

    alias Dav.Web.Principal

    @impl Dav.Web.Report
    def run(resource, body, depth, options)

    # "The request MUST include a Depth header with value 0." A report
    # that walked a tree following every href in every property is a
    # different and much more expensive request.
    def run(%Resource{}, _body, depth, _options) when depth != 0, do: {:error, :malformed}

    def run(%Resource{} = resource, body, _depth, options) do
      with {:ok, document} <- Xml.parse(body),
           :ok <- shallow(document) do
        {:ok, [Principal.expand(resource, document, options)]}
      end
    end

    # One level of expansion, not a tree. Each `DAV:property` inside a
    # `DAV:property` names what to read from the resources the outer
    # one points at; a third level asks the server to follow hrefs
    # found in *those* properties, which this report does not do —
    # and saying so is more use to a client than an answer quietly
    # missing the part it asked for.
    defp shallow(document) do
      if Principal.nested?(document), do: {:error, :not_implemented}, else: :ok
    end
  end

  @searchable [{Xml.dav(), "displayname"}, {Xml.caldav(), "calendar-user-address-set"}]

  @doc """
  The properties a report asked for.

  ### Arguments

  * `document` is the parsed request body.

  ### Returns

  * A list of qualified names, empty when none were named.

  """
  @spec requested(Xml.element()) :: [Xml.qname()]
  def requested(document) do
    case find(document, "prop") do
      nil -> []
      element -> for child <- element.children, do: child.name
    end
  end

  @doc """
  Every resource in a collection, and the collection itself.

  ### Arguments

  * `collection` is the report's target.

  * `options` carries `:store` and `:context`.

  ### Returns

  * A list of resources.

  """
  @spec members(Resource.t(), map()) :: [Resource.t()]
  def members(collection, %{store: store, context: context}) do
    case store.children(collection, context) do
      {:ok, children} -> [collection | children]
      _nothing -> [collection]
    end
  end

  @doc """
  Whether a resource belongs to the current user.

  ### Arguments

  * `resource` is the candidate.

  * `document` is the request, which may name the property to follow.

  * `options` carries `:store`, `:context` and `:principal`.

  ### Returns

  * `true` when the resource is the user's own principal, or is owned
    by them — their proxy groups included.

  ### Examples

      iex> {:ok, document} = Dav.Xml.parse(~s(<?xml version="1.0"?><D:principal-match xmlns:D="DAV:"><D:self/></D:principal-match>))
      iex> resource = %Dav.Web.Resource{path: ["principals", "me"], collection?: true, types: [Dav.Web.Acl.principal()]}
      iex> Dav.Web.Principal.mine?(resource, document, %{principal: "/principals/me/"})
      true

  """
  @spec mine?(Resource.t(), Xml.element(), map()) :: boolean()
  def mine?(resource, document, options) do
    whose = canonical_caller(options)

    if find(document, "self"),
      do: Acl.principal?(resource) and matches_caller?(resource, whose, options),
      else: held_by?(resource, whose, options)
  end

  # RFC 3744 section 9.3: a principal matches the current user when it
  # *is* them — and a group principal matches when they are one of its
  # members.
  defp matches_caller?(_resource, nil, _options), do: false

  defp matches_caller?(%Resource{} = resource, whose, options) do
    identity_of(resource) == whose or member_of?(resource, whose, options)
  end

  defp member_of?(%Resource{} = group, whose, %{store: store, context: context} = options) do
    with true <- Store.supports?(store, :properties),
         %{} = properties <- store.properties(group, context),
         {:hrefs, members} <- Map.get(properties, {Xml.dav(), "group-member-set"}) do
      Enum.any?(members, &(canonical_of(&1, options) == whose))
    else
      _no_members -> false
    end
  end

  defp member_of?(_group, _whose, _options), do: false

  @doc """
  The sub-principals of a collection member, for a principal walk.

  ### Arguments

  * `member` is the candidate, from the surface listing.

  * `collection` is the walked collection itself, never descended.

  * `options` carries `:store` and `:context`.

  ### Returns

  * The member's own members when it is a principal, else `[]`.

  """
  @spec sub_principals(Resource.t(), Resource.t(), map()) :: [Resource.t()]
  def sub_principals(member, collection, options) do
    if member != collection and Acl.principal?(member),
      do: tl(members(member, options)),
      else: []
  end

  defp held_by?(_resource, nil, _options), do: false

  defp held_by?(%Resource{} = resource, whose, options) do
    identity_of(resource) == whose or
      (is_binary(resource.owner) and canonical_of(resource.owner, options) == whose)
  end

  # `owner` says who a principal belongs to; for a sub-principal — a
  # proxy group — that is its holder, not itself.
  defp identity_of(%Resource{owner: owner, path: path}) when is_binary(owner) do
    case List.last(path) do
      leaf when leaf in ["calendar-proxy-read", "calendar-proxy-write"] -> owner <> leaf <> "/"
      _self_owned -> owner
    end
  end

  defp identity_of(%Resource{} = resource), do: Resource.href(resource)

  defp canonical_caller(options) do
    case Map.get(options, :principal) do
      principal when is_binary(principal) -> canonical_of(principal, options)
      _nobody -> nil
    end
  end

  defp canonical_of(href, %{store: store, context: context}) do
    case store.resolve(Store.segments(href), context) do
      {:ok, %Resource{} = found} -> identity_of(found)
      _unknown -> href
    end
  end

  defp canonical_of(href, _options), do: href

  @doc """
  The property searches a `principal-property-search` asked for.

  ### Arguments

  * `document` is the parsed request body.

  ### Returns

  * A list of `{qname, text}` pairs.

  """
  @spec searches(Xml.element()) :: [{Xml.qname(), String.t()}]
  def searches(document) do
    for search <- children(document, "property-search"),
        property <- children(search, "prop"),
        name <- Enum.map(property.children, & &1.name),
        match = find(search, "match"),
        do: {name, String.trim(match.text)}
  end

  @doc """
  Whether a principal matches every search.

  Matching is a case-insensitive substring test, which is what a
  client typing into a name field expects.

  ### Arguments

  * `principal` is the candidate resource.

  * `searches` is the list from `searches/1`.

  ### Returns

  * `true` when every search matches.

  """
  @spec matches?(Resource.t(), [{Xml.qname(), String.t()}]) :: boolean()
  def matches?(_principal, []), do: false

  def matches?(principal, searches) do
    Enum.all?(searches, fn {name, text} -> contains?(principal, name, text) end)
  end

  defp contains?(principal, name, text) do
    case Properties.fetch(principal, name) do
      {:ok, value} when is_binary(value) ->
        String.contains?(String.downcase(value), String.downcase(text))

      {:ok, {:hrefs, hrefs}} ->
        Enum.any?(hrefs, &String.contains?(String.downcase(&1), String.downcase(text)))

      _absent ->
        false
    end
  end

  @doc """
  One resource's part of a report's multistatus.

  ### Arguments

  * `resource` is the resource being described.

  * `wanted` is the list of property names.

  * `options` may carry `:store` and `:context`, in which case
    properties the store holds are read as well as those the resource
    carries. Without them only the resource's own are visible.

  ### Returns

  * A `{href, propstats}` pair.

  """
  @spec response(Resource.t(), [Xml.qname()], map()) ::
          {String.t(), [{String.t(), [{Xml.qname(), Xml.value()}]}]}
  def response(resource, wanted, options \\ %{}) do
    {found, missing} =
      Enum.reduce(wanted, {[], []}, fn name, {found, missing} ->
        case fetch(resource, name, options) do
          {:ok, value} -> {found ++ [{name, value}], missing}
          :error -> {found, missing ++ [{name, nil}]}
        end
      end)

    propstats =
      Enum.reject(
        [{"HTTP/1.1 200 OK", found}, {"HTTP/1.1 404 Not Found", missing}],
        fn {_status, properties} -> properties == [] end
      )

    {Resource.href(resource), propstats}
  end

  # A property PROPFIND can read is a property a report can return.
  # `DAV:group-member-set` and `DAV:group-membership` are why: they
  # are the store's to answer rather than the resource struct's, and a
  # client that can read a group's members but not expand them is back
  # to the round trips `expand-property` exists to save.
  defp fetch(resource, name, options) do
    with :error <- Properties.fetch(resource, name),
         :error <- stored(resource, name, options) do
      contributed(resource, name, options)
    end
  end

  # What an extension computes — a principal's proxy memberships, say
  # — expands like anything the store holds.
  defp contributed(resource, name, %{store: store, context: context} = options) do
    collection =
      case store.resolve(Enum.drop(resource.path, -1), context) do
        {:ok, parent} -> parent
        _no_parent -> nil
      end

    options
    |> Map.get(:hooks, [])
    |> Enum.filter(&(Code.ensure_loaded?(&1) and function_exported?(&1, :properties, 3)))
    |> Enum.flat_map(& &1.properties(resource, collection, options))
    |> Map.new()
    |> Map.fetch(name)
  end

  defp contributed(_resource, _name, _options), do: :error

  defp stored(resource, name, %{store: store, context: context}) do
    if Store.supports?(store, :properties) do
      Map.fetch(store.properties(resource, context), name)
    else
      :error
    end
  end

  defp stored(_resource, _name, _options), do: :error

  @doc """
  The principals named in a resource's access control list.

  ### Arguments

  * `resource` is the resource whose ACL is read.

  ### Returns

  * A list of principal URLs, in ACL order.

  ### Examples

      iex> Dav.Web.Principal.acl_principals(%Dav.Web.Resource{owner: "/principals/users/kip/"})
      ["/principals/users/kip/"]

      iex> Dav.Web.Principal.acl_principals(%Dav.Web.Resource{})
      []

  """
  @spec acl_principals(Resource.t()) :: [String.t()]
  def acl_principals(%Resource{owner: nil}), do: []
  def acl_principals(%Resource{owner: owner}), do: [owner]

  @doc """
  Resolve a principal URL to its resource.

  ### Arguments

  * `href` is the principal URL.

  * `options` carries `:store` and `:context`.

  ### Returns

  * A single-element list, or an empty one when the URL is not hosted
    here — a principal on another server has no properties to report.

  """
  @spec resolved(String.t(), map()) :: [Resource.t()]
  def resolved(href, options) do
    case resolve(href, options) do
      {:ok, resource} -> [resource]
      _absent -> []
    end
  end

  @doc """
  The searchable property set document.

  ### Returns

  * The document as iodata.

  ### Examples

      iex> Dav.Web.Principal.search_property_set() |> IO.iodata_to_binary() =~ "displayname"
      true

  """
  @spec search_property_set() :: [iodata()]
  def search_property_set do
    [
      ~s(<?xml version="1.0" encoding="utf-8"?>),
      ~s(<D:principal-search-property-set xmlns:D="DAV:" xmlns:C="),
      Xml.caldav(),
      ~s(">),
      Enum.map(@searchable, &searchable/1),
      "</D:principal-search-property-set>"
    ]
  end

  defp searchable({namespace, local}) do
    prefix = if namespace == Xml.dav(), do: "D", else: "C"

    [
      "<D:principal-search-property>",
      "<D:prop><",
      prefix,
      ":",
      local,
      "/></D:prop>",
      "<D:description>",
      local,
      "</D:description>",
      "</D:principal-search-property>"
    ]
  end

  @doc """
  Whether an `expand-property` body asks for more than one level.

  ### Arguments

  * `document` is the parsed `DAV:expand-property` body.

  ### Returns

  * `true` when a `DAV:property` three deep asks the server to follow
    hrefs found in an already-expanded property, and `false`
    otherwise.

  ### Examples

      iex> body = ~s(<?xml version="1.0"?><D:expand-property xmlns:D="DAV:"><D:property name="a"><D:property name="b"/></D:property></D:expand-property>)
      iex> {:ok, document} = Dav.Xml.parse(body)
      iex> Dav.Web.Principal.nested?(document)
      false

      iex> body = ~s(<?xml version="1.0"?><D:expand-property xmlns:D="DAV:"><D:property name="a"><D:property name="b"><D:property name="c"/></D:property></D:property></D:expand-property>)
      iex> {:ok, document} = Dav.Xml.parse(body)
      iex> Dav.Web.Principal.nested?(document)
      true

  """
  @spec nested?(Xml.element()) :: boolean()
  def nested?(document) do
    Enum.any?(children(document, "property"), fn outer ->
      Enum.any?(children(outer, "property"), &(children(&1, "property") != []))
    end)
  end

  @doc """
  Expand the properties a resource's hrefs point at.

  ### Arguments

  * `resource` is the report's target.

  * `document` is the parsed request.

  * `options` carries `:store` and `:context`.

  ### Returns

  * A `{href, propstats}` pair whose values carry the referenced
    resources inline.

  """
  @spec expand(Resource.t(), Xml.element(), map()) ::
          {String.t(), [{String.t(), [{Xml.qname(), Xml.value()}]}]}
  def expand(resource, document, options) do
    {found, missing} =
      Enum.split_with(children(document, "property"), &known?(resource, qname(&1), options))

    propstats =
      [
        {"HTTP/1.1 200 OK", for(element <- found, do: expanded(resource, element, options))},
        {"HTTP/1.1 404 Not Found", for(element <- missing, do: {qname(element), nil})}
      ]
      |> Enum.reject(fn {_status, properties} -> properties == [] end)

    {Resource.href(resource), propstats}
  end

  # A property the resource does not have is reported missing rather
  # than expanded to nothing: "no such property" and "a property whose
  # references expanded to nothing" are different answers.
  defp known?(resource, name, options) do
    hrefs_of(resource, name, options) != [] or
      match?({:ok, _value}, Properties.fetch(resource, name))
  end

  # The referenced resources' own properties, rendered inside the
  # property that pointed at them — as bare `DAV:response` elements,
  # since a `DAV:multistatus` nested in a property value is not
  # something the grammar allows.
  defp expanded(resource, element, options) do
    name = qname(element)

    inner =
      resource
      |> hrefs_of(name, options)
      |> Enum.flat_map(fn href ->
        with {:ok, referenced} <- resolve(href, options),
             true <- visible?(referenced, options) do
          [response(referenced, requested_by(element), options)]
        else
          _absent_or_hidden -> []
        end
      end)
      |> then(&Xml.responses/1)

    {name, {:elements, [Xml.dav(), Xml.caldav()], inner}}
  end

  # "The server MUST NOT return properties for a resource the client
  # does not have access to." Without that, a property naming another
  # user's calendar turns this report into a way to read it.
  #
  # A principal is discoverable by design — `principal-property-search`
  # exists to find other people — and a resource with no owner belongs
  # to nobody in particular. Everything else is expanded only for the
  # principal that owns it.
  #
  # This under-discloses rather than over-discloses: a calendar shared
  # *with* the caller is owned by the sharer, so it is not expanded
  # even though the caller may read it. Deciding that needs a
  # readability question the hook behaviour does not yet ask, and a
  # missing expansion costs a round trip where the other error costs
  # somebody their calendar.
  defp visible?(resource, options) do
    Acl.principal?(resource) or is_nil(resource.owner) or
      resource.owner == Map.get(options, :principal)
  end

  defp requested_by(element) do
    for child <- children(element, "property"), do: qname(child)
  end

  defp qname(element) do
    namespace = Map.get(element.attributes, "namespace", Xml.dav())

    {namespace, Map.get(element.attributes, "name", "")}
  end

  # `DAV:current-user-principal` is supplied by the plug rather than
  # the resource, because it answers "who am I" — so expanding it has
  # to look where the answer actually is.
  defp hrefs_of(resource, {"DAV:", "current-user-principal"}, %{principal: principal})
       when is_binary(principal) do
    _ = resource
    [principal]
  end

  defp hrefs_of(resource, name, options) do
    case fetch(resource, name, options) do
      {:ok, {:hrefs, hrefs}} -> hrefs
      _not_href_valued -> []
    end
  end

  defp resolve(href, %{store: store, context: context}) do
    store.resolve(Store.segments(href), context)
  end

  defp find(element, name), do: Enum.find(element.children, &named?(&1, name))

  defp children(element, name), do: Enum.filter(element.children, &named?(&1, name))

  defp named?(%{name: {_namespace, local}}, local), do: true
  defp named?(_element, _local), do: false
end
