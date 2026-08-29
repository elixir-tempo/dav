defmodule Dav.Cal.Filter do
  @moduledoc """
  The query language of `calendar-query` — RFC 4791 section 9.7.

  A filter is a tree that mirrors the shape of the calendar data it
  selects: a component filter matching `VCALENDAR`, containing one
  matching `VEVENT`, containing a time range. Nothing in it addresses
  a resource by name; it describes what the data must look like.

      <C:filter>
        <C:comp-filter name="VCALENDAR">
          <C:comp-filter name="VEVENT">
            <C:time-range start="20260601T000000Z" end="20260701T000000Z"/>
          </C:comp-filter>
        </C:comp-filter>
      </C:filter>

  ### The grammar, and what is implemented

  The specification allows each filter to be *either* `is-not-defined`
  or a set of conditions, never both:

      comp-filter  := is-not-defined | (time-range?, prop-filter*, comp-filter*)
      prop-filter  := is-not-defined | ((time-range | text-match)?, param-filter*)
      param-filter := is-not-defined | text-match?

  All three are parsed. What this module does **not** do is evaluate
  them — see `Dav.Cal.Query` — and a filter is deliberately a value
  rather than a predicate so that it can be inspected and tested
  without calendar data to hand.

  """

  alias Dav.Xml

  @typedoc "A `text-match` condition."
  @type text_match :: %{value: String.t(), collation: String.t(), negate?: boolean()}

  @typedoc "A half-open range of instants, either end open."
  @type time_range :: {String.t() | nil, String.t() | nil}

  @typedoc "A filter over a component, property or parameter."
  @type t :: %__MODULE__{
          kind: :comp | :prop | :param,
          name: String.t(),
          undefined?: boolean(),
          time_range: time_range() | nil,
          text_match: text_match() | nil,
          children: [t()]
        }

  defstruct kind: :comp,
            name: nil,
            undefined?: false,
            time_range: nil,
            text_match: nil,
            children: []

  @doc """
  Read a `CALDAV:filter` element into a filter.

  ### Arguments

  * `element` is the `filter` element from `Dav.Xml.parse/1`.

  ### Returns

  * `{:ok, filter}` for the single component filter a `filter` element
    must contain; or

  * `{:error, :malformed}` when it contains anything else — the
    grammar is `<!ELEMENT filter (comp-filter)>`, exactly one.

  ### Examples

      iex> body = ~s(<C:filter xmlns:C="urn:ietf:params:xml:ns:caldav"><C:comp-filter name="VCALENDAR"><C:comp-filter name="VEVENT"/></C:comp-filter></C:filter>)
      iex> {:ok, element} = Dav.Xml.parse(body)
      iex> {:ok, filter} = Dav.Cal.Filter.from_element(element)
      iex> {filter.name, Enum.map(filter.children, & &1.name)}
      {"VCALENDAR", ["VEVENT"]}

  """
  @spec from_element(Xml.element()) :: {:ok, t()} | {:error, :malformed}
  def from_element(%{name: {_namespace, "filter"}, children: children}) do
    case Enum.filter(children, &comp_filter?/1) do
      [only] -> {:ok, build(:comp, only)}
      _not_exactly_one -> {:error, :malformed}
    end
  end

  def from_element(_other), do: {:error, :malformed}

  defp comp_filter?(%{name: {_namespace, "comp-filter"}}), do: true
  defp comp_filter?(_other), do: false

  defp build(kind, element) do
    %__MODULE__{
      kind: kind,
      name: Map.get(element.attributes, "name"),
      undefined?: Enum.any?(element.children, &local?(&1, "is-not-defined")),
      time_range: time_range(element),
      text_match: text_match(element),
      children: nested(element)
    }
  end

  # A filter is either `is-not-defined` or a set of conditions, so a
  # filter that says the component is absent carries nothing else —
  # anything alongside it is ignored rather than half-applied.
  defp nested(%{children: children}) do
    for child <- children, kind = kind_of(child), do: build(kind, child)
  end

  defp kind_of(%{name: {_namespace, "comp-filter"}}), do: :comp
  defp kind_of(%{name: {_namespace, "prop-filter"}}), do: :prop
  defp kind_of(%{name: {_namespace, "param-filter"}}), do: :param
  defp kind_of(_other), do: nil

  defp time_range(%{children: children}) do
    case Enum.find(children, &local?(&1, "time-range")) do
      nil -> nil
      element -> {attribute(element, "start"), attribute(element, "end")}
    end
  end

  defp text_match(%{children: children}) do
    case Enum.find(children, &local?(&1, "text-match")) do
      nil ->
        nil

      element ->
        %{
          value: element.text,
          collation: Map.get(element.attributes, "collation", "i;ascii-casemap"),
          negate?: Map.get(element.attributes, "negate-condition", "no") == "yes"
        }
    end
  end

  defp attribute(element, name), do: Map.get(element.attributes, name)

  defp local?(%{name: {_namespace, local}}, local), do: true
  defp local?(_element, _local), do: false

  @doc """
  Whether a calendar component satisfies this filter.

  ### How the nesting reads

  A nested filter constrains the component it sits *inside*, rather
  than describing a component of its own. A `comp-filter` for `VEVENT`
  inside one for `VCALENDAR` asks "does this VCALENDAR contain a
  matching VEVENT", and `is-not-defined` on it asks the opposite:
  "does it contain none". That is why matching walks parent to child
  rather than comparing two trees.

  Within one level the conditions are conjunctive — every property
  filter and every component filter must be satisfied — but each is
  satisfied by *any* one property or component that matches it.

  ### Time ranges

  `time-range` is not answered here. It needs `DTSTART`, `DURATION`
  and recurrence expanded across `RRULE`, `RDATE` and `EXDATE`, which
  is meaning rather than structure and belongs to Tempo. Supply it as
  the `:time_range` option — a function of the component and the
  `{start, end}` pair.

  Without one, a filter that uses a time range **raises**. Quietly
  matching everything would hand a client data it did not ask for, and
  quietly matching nothing would look like an empty calendar; both are
  worse than a loud failure during development.

  ### Arguments

  * `filter` is a `t:t/0`, normally from `from_element/1`.

  * `component` is a component from `Dav.Cal.ICalendar.parse/1`.

  ### Options

  * `:time_range` is a two-argument function, given the component and
    a `{start, end}` tuple, returning a boolean.

  ### Returns

  * `true` when the component satisfies the filter.

  ### Examples

      iex> body = ~s(<C:filter xmlns:C="urn:ietf:params:xml:ns:caldav"><C:comp-filter name="VCALENDAR"><C:comp-filter name="VEVENT"/></C:comp-filter></C:filter>)
      iex> {:ok, element} = Dav.Xml.parse(body)
      iex> {:ok, filter} = Dav.Cal.Filter.from_element(element)
      iex> {:ok, calendar} = Dav.Cal.ICalendar.parse("BEGIN:VCALENDAR\\r\\nBEGIN:VEVENT\\r\\nEND:VEVENT\\r\\nEND:VCALENDAR\\r\\n")
      iex> Dav.Cal.Filter.match?(filter, calendar)
      true

      iex> body = ~s(<C:filter xmlns:C="urn:ietf:params:xml:ns:caldav"><C:comp-filter name="VCALENDAR"><C:comp-filter name="VTODO"/></C:comp-filter></C:filter>)
      iex> {:ok, element} = Dav.Xml.parse(body)
      iex> {:ok, filter} = Dav.Cal.Filter.from_element(element)
      iex> {:ok, calendar} = Dav.Cal.ICalendar.parse("BEGIN:VCALENDAR\\r\\nBEGIN:VEVENT\\r\\nEND:VEVENT\\r\\nEND:VCALENDAR\\r\\n")
      iex> Dav.Cal.Filter.match?(filter, calendar)
      false

  """
  @spec match?(t(), map(), keyword()) :: boolean()
  def match?(%__MODULE__{} = filter, component, options \\ []) do
    filter.name == component.name and satisfied?(filter, component, options)
  end

  defp satisfied?(%__MODULE__{undefined?: true}, _component, _options), do: false

  defp satisfied?(%__MODULE__{} = filter, component, options) do
    in_range?(filter, component, options) and
      Enum.all?(filter.children, &child_satisfied?(&1, component, options))
  end

  # A child filter is satisfied by *any* matching child, or — when it
  # says `is-not-defined` — by there being none.
  defp child_satisfied?(%__MODULE__{kind: :comp} = filter, component, options) do
    present = Enum.filter(component.components, &(&1.name == filter.name))

    if filter.undefined? do
      present == []
    else
      Enum.any?(present, &satisfied?(filter, &1, options))
    end
  end

  defp child_satisfied?(%__MODULE__{kind: :prop} = filter, component, options) do
    present = Enum.filter(component.properties, &(&1.name == filter.name))

    if filter.undefined? do
      present == []
    else
      Enum.any?(present, &property_satisfied?(filter, &1, options))
    end
  end

  defp child_satisfied?(%__MODULE__{kind: :param} = filter, property, _options) do
    case Map.fetch(property.parameters, filter.name) do
      :error -> filter.undefined?
      {:ok, _value} when filter.undefined? -> false
      {:ok, value} -> matches_text?(filter.text_match, value)
    end
  end

  defp property_satisfied?(%__MODULE__{} = filter, property, options) do
    matches_text?(filter.text_match, property.value) and
      in_range?(filter, property, options) and
      Enum.all?(filter.children, &child_satisfied?(&1, property, options))
  end

  defp matches_text?(nil, _value), do: true

  # `text-match` is a substring test, not equality, and
  # `negate-condition` inverts the whole result rather than the
  # comparison. The default collation is case-insensitive ASCII.
  defp matches_text?(%{value: wanted, collation: collation, negate?: negate?}, value) do
    found? =
      case collation do
        "i;octet" -> String.contains?(value, wanted)
        _case_insensitive -> String.contains?(String.downcase(value), String.downcase(wanted))
      end

    if negate?, do: not found?, else: found?
  end

  defp in_range?(%__MODULE__{time_range: nil}, _target, _options), do: true

  defp in_range?(%__MODULE__{time_range: range}, target, options) do
    case Keyword.get(options, :time_range) do
      nil ->
        raise ArgumentError,
              "this filter uses a CALDAV:time-range, which needs calendar semantics to " <>
                "answer. Pass a :time_range function — see Dav.Cal.Filter.match?/3."

      evaluate ->
        evaluate.(target, range)
    end
  end
end
