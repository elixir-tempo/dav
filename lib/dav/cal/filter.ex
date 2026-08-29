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
end
