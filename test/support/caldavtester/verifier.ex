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

  alias Dav.CalDAVTester.Scenario.Verify
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
  @spec run(Verify.t(), Plug.Conn.t()) :: outcome()
  def run(%Verify{callback: "statusCode", args: args}, conn) do
    expected = Map.get(args, "status", ["2xx"])

    if Enum.any?(expected, &status_matches?(&1, conn.status)) do
      :passed
    else
      {:failed, "status #{conn.status}, expected #{Enum.join(expected, ", ")}"}
    end
  end

  def run(%Verify{callback: "header", args: args}, conn) do
    args |> Map.get("header", []) |> each(&header_matches(&1, conn))
  end

  def run(%Verify{callback: "multistatusItems", args: args}, conn) do
    with :ok <- multistatus_status(conn),
         {:ok, responses} <- responses(conn) do
      multistatus_items(args, responses, conn)
    end
  end

  def run(%Verify{callback: "propfindItems", args: args}, conn) do
    expected = args |> Map.get("status", ["207"]) |> List.first() |> String.to_integer()

    with :ok <- expect_status(conn, expected),
         {:ok, responses} <- responses(conn) do
      propfind_items(args, responses)
    end
  end

  def run(%Verify{callback: callback}, _conn) do
    {:skipped, "verifier #{callback} is not implemented"}
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
      {:ok, document} -> {:ok, Enum.map(elements(document, "response"), &classify/1)}
      _unparseable -> {:failed, "response is not valid XML"}
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

    cond do
      counted = single(args, "count") ->
        compare(MapSet.size(ok) - 1, counted, "items")

      counted = single(args, "totalcount") ->
        compare(MapSet.size(ok), counted, "items")

      counted = single(args, "responsecount") ->
        compare(MapSet.size(ok) + MapSet.size(bad), counted, "responses")

      href_sets?(args) ->
        hrefs(args, ok, bad, conn)

      true ->
        {:skipped, "multistatusItems form not implemented: #{inspect(Map.keys(args))}"}
    end
  end

  defp href_sets?(args), do: Enum.any?(~w(okhrefs badhrefs nohrefs), &Map.has_key?(args, &1))

  defp hrefs(args, ok, bad, conn) do
    prefix = prefix(args, conn)
    expected_ok = href_set(args, "okhrefs", prefix)
    expected_bad = href_set(args, "badhrefs", prefix)
    absent = href_set(args, "nohrefs", prefix)

    [
      {"missing (OK)", MapSet.difference(expected_ok, ok)},
      {"unexpected (OK)", MapSet.difference(ok, expected_ok)},
      {"missing (BAD)", MapSet.difference(expected_bad, bad)},
      {"unexpected (BAD)", MapSet.difference(bad, expected_bad)},
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

  defp href_set(args, name, prefix) do
    for href <- Map.get(args, name, []), into: MapSet.new() do
      href
      |> then(&if String.starts_with?(&1, "/"), do: &1, else: Path.join(prefix, &1))
      |> URI.decode()
      |> String.trim_trailing("/")
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

    cond do
      counted = single(args, "count") ->
        compare(length(responses), counted, "responses")

      Enum.any?(ok_specs ++ bad_specs, &xml_valued?/1) ->
        {:skipped, "propfindItems compares a serialised XML value"}

      true ->
        each(responses, &properties_match(&1, ok_specs, bad_specs))
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

  defp xml_valued?({_property, value}), do: is_binary(value) and String.starts_with?(value, "<")

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
        :passed
    end
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

  defp single(args, name) do
    case single_value(args, name) do
      nil ->
        nil

      value ->
        case Integer.parse(value) do
          {number, ""} -> number
          _unreadable -> nil
        end
    end
  end

  defp single_value(args, name) do
    case Map.get(args, name, []) do
      [value] -> value
      _absent_or_many -> nil
    end
  end

  defp compare(actual, actual, _noun), do: :passed
  defp compare(actual, expected, noun), do: {:failed, "#{actual} #{noun}, expected #{expected}"}

  defp elements(element, name) do
    matching = Enum.filter(element.children, &local?(&1, name))
    matching ++ Enum.flat_map(element.children, &elements(&1, name))
  end

  defp local?(%{name: {_namespace, name}}, name), do: true
  defp local?(_element, _name), do: false

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
end
