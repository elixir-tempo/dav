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
    Regex.replace(~r/\$[A-Za-z0-9_-]+:/, text, fn key ->
      Map.get(substitutions, key, key)
    end)
  end

  ## --- reading ----------------------------------------------------

  defp pairs(document) do
    document
    |> elements("substitutions")
    |> Enum.flat_map(&entries/1)
    |> Map.new()
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
    expanded = Map.new(substitutions, fn {key, value} -> {key, expand(value, substitutions)} end)

    if expanded == substitutions, do: expanded, else: resolve(expanded, budget - 1)
  end

  defp elements(element, name) do
    matching = for child <- element.children, match?(%{name: {_ns, ^name}}, child), do: child
    matching ++ Enum.flat_map(element.children, &elements(&1, name))
  end
end
