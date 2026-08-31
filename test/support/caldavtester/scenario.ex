defmodule Dav.CalDAVTester.Scenario do
  @moduledoc """
  One CalDAVTester scenario file, as data.

  A scenario is a sequence of HTTP requests with the responses a
  conformant server must give. The grammar is `caldavtest.dtd`, and
  the shape it describes is:

      caldavtest → require-feature?, start, test-suite*, end
      test-suite → test*
      test       → request+
      request    → method, ruri*, header*, data?, verify*

  Parsing it is separate from running it so that a scenario can be
  inspected, counted and filtered without a server — which is how the
  suite gets measured rather than guessed at.

  Only the parts the runner acts on are read. The suite also carries
  `grabproperty`, `grabelement` and friends, which feed values from one
  response into a later request; those are recorded as unsupported so
  a scenario needing them is skipped openly instead of quietly
  producing wrong results.

  """

  alias Dav.CalDAVTester.Document

  defmodule Verify do
    @moduledoc """
    One response check: a verifier callback and its arguments.

    A check carries its own feature gates. The same request often has
    two, expecting different results from a server that splits
    calendars and one that does not — running both means one of them
    always fails.
    """
    defstruct [:callback, args: %{}, features: [], excluded: []]

    @type t :: %__MODULE__{
            callback: String.t(),
            args: %{optional(String.t()) => [String.t()]},
            features: [String.t()],
            excluded: [String.t()]
          }
  end

  defmodule Request do
    @moduledoc "One HTTP request in a scenario, with the checks on its response."
    defstruct [
      :method,
      :data,
      :iterate_data?,
      uris: [],
      headers: [],
      verifiers: [],
      grabs: [],
      user: nil,
      password: nil,
      authenticate?: true,
      end_delete?: false,
      features: [],
      excluded: []
    ]

    @type t :: %__MODULE__{
            method: String.t(),
            data:
              %{
                content_type: String.t(),
                filepath: String.t() | nil,
                substitutions: [{String.t(), String.t()}]
              }
              | nil,
            iterate_data?: boolean(),
            uris: [String.t()],
            headers: [{String.t(), String.t()}],
            verifiers: [Verify.t()],
            grabs: [{atom(), String.t() | nil, String.t() | nil}],
            user: String.t() | nil,
            password: String.t() | nil,
            authenticate?: boolean(),
            end_delete?: boolean(),
            features: [String.t()],
            excluded: [String.t()]
          }
  end

  defmodule Test do
    @moduledoc "One named test: a sequence of requests that must all pass."
    defstruct [:name, :description, requests: [], ignore?: false, features: [], excluded: []]

    @type t :: %__MODULE__{
            name: String.t(),
            description: String.t() | nil,
            requests: [Request.t()],
            ignore?: boolean(),
            features: [String.t()],
            excluded: [String.t()]
          }
  end

  defmodule Suite do
    @moduledoc "A named group of tests within a scenario."
    defstruct [:name, tests: [], ignore?: false, change_uid?: false, features: [], excluded: []]

    @type t :: %__MODULE__{
            name: String.t(),
            tests: [Test.t()],
            ignore?: boolean(),
            change_uid?: boolean(),
            features: [String.t()],
            excluded: [String.t()]
          }
  end

  defstruct [:path, :description, suites: [], setup: [], teardown: [], features: []]

  @type t :: %__MODULE__{
          path: Path.t(),
          description: String.t() | nil,
          suites: [Suite.t()],
          setup: [Request.t()],
          teardown: [Request.t()],
          features: [String.t()]
        }

  @doc """
  Read a scenario file.

  ### Arguments

  * `path` is a scenario under `scripts/tests`.

  ### Returns

  * `{:ok, scenario}`; or

  * `{:error, :malformed}` when the file cannot be read as XML.

  ### Examples

      iex> {:ok, scenario} = Dav.CalDAVTester.Scenario.read("rfc/conformance/caldavtester/scripts/tests/CalDAV/options.xml")
      iex> scenario.description
      "Test OPTIONS, DAV header behavior"

      iex> {:ok, scenario} = Dav.CalDAVTester.Scenario.read("rfc/conformance/caldavtester/scripts/tests/CalDAV/options.xml")
      iex> Enum.map(scenario.suites, & &1.name)
      ["OPTIONS+DAV", "PROPFIND - no DAV"]

  """
  @spec read(Path.t()) :: {:ok, t()} | {:error, :malformed}
  def read(path) do
    case Document.read(path) do
      {:ok, document} -> {:ok, scenario(document, path)}
      error -> error
    end
  end

  @doc """
  Every test in a scenario, paired with the suite that holds it.

  ### Arguments

  * `scenario` is a `t:t/0`.

  ### Returns

  * A list of `{suite, test}` pairs, ignoring suites and tests marked
    `ignore='yes'` — the suite's own way of saying a case is not
    expected to run.

  ### Examples

      iex> {:ok, scenario} = Dav.CalDAVTester.Scenario.read("rfc/conformance/caldavtester/scripts/tests/CalDAV/options.xml")
      iex> Dav.CalDAVTester.Scenario.tests(scenario) |> length()
      4

  """
  @spec tests(t()) :: [{Suite.t(), Test.t()}]
  def tests(%__MODULE__{} = scenario, features \\ nil) do
    for suite <- scenario.suites,
        not suite.ignore?,
        applicable?(scenario, features),
        applicable?(suite, features),
        test <- suite.tests,
        not test.ignore?,
        applicable?(test, features),
        do: {suite, test}
  end

  @doc """
  Whether a scenario, suite, test or request applies to a server.

  The suite is written against a server that declares what it supports,
  and gates 850 of its own blocks on those declarations. A server that
  never claims `dropbox` is not failing `dropbox` tests — it is not
  being asked them. Ignoring this makes a conformance figure measure
  the wrong thing in both directions.

  ### Arguments

  * `item` is anything carrying `features` and `excluded` lists.

  * `features` is the set the server declares, or `nil` to run
    everything.

  ### Returns

  * `true` when every required feature is declared and no excluded one
    is.

  ### Examples

      iex> suite = %Dav.CalDAVTester.Scenario.Suite{name: "x", features: ["caldav"]}
      iex> Dav.CalDAVTester.Scenario.applicable?(suite, MapSet.new(["caldav"]))
      true

      iex> suite = %Dav.CalDAVTester.Scenario.Suite{name: "x", features: ["dropbox"]}
      iex> Dav.CalDAVTester.Scenario.applicable?(suite, MapSet.new(["caldav"]))
      false

  """
  @spec applicable?(map(), MapSet.t() | nil) :: boolean()
  def applicable?(_item, nil), do: true

  def applicable?(item, features) do
    required = Map.get(item, :features, [])
    excluded = Map.get(item, :excluded, [])

    Enum.all?(required, &MapSet.member?(features, &1)) and
      not Enum.any?(excluded, &MapSet.member?(features, &1))
  end

  ## --- reading ----------------------------------------------------

  defp scenario(document, path) do
    %__MODULE__{
      path: path,
      description: Document.text(document, "description"),
      features: features(document, "require-feature"),
      setup: requests_in(Document.child(document, "start")),
      teardown: requests_in(Document.child(document, "end")),
      suites: Enum.map(Document.children(document, "test-suite"), &suite/1)
    }
  end

  defp suite(element) do
    %Suite{
      name: Map.get(element.attributes, "name", ""),
      ignore?: yes?(element, "ignore"),
      change_uid?: yes?(element, "change-uid"),
      features: features(element, "require-feature"),
      excluded: features(element, "exclude-feature"),
      tests: Enum.map(Document.children(element, "test"), &test/1)
    }
  end

  defp test(element) do
    %Test{
      name: Map.get(element.attributes, "name", ""),
      description: Document.text(element, "description"),
      ignore?: yes?(element, "ignore"),
      features: features(element, "require-feature"),
      excluded: features(element, "exclude-feature"),
      requests: requests_in(element)
    }
  end

  defp requests_in(nil), do: []
  defp requests_in(element), do: Enum.map(Document.children(element, "request"), &request/1)

  defp request(element) do
    %Request{
      method: Document.text(element, "method"),
      uris: Enum.map(Document.children(element, "ruri"), &String.trim(&1.text)),
      headers: Enum.map(Document.children(element, "header"), &header/1),
      data: data(Document.child(element, "data")),
      iterate_data?: yes?(element, "iterate-data"),
      verifiers: Enum.map(Document.children(element, "verify"), &verify/1),
      grabs: grabs(element),
      user: Map.get(element.attributes, "user"),
      password: Map.get(element.attributes, "pswd"),
      authenticate?: Map.get(element.attributes, "auth", "yes") == "yes",
      end_delete?: yes?(element, "end-delete"),
      features: features(element, "require-feature"),
      excluded: features(element, "exclude-feature")
    }
  end

  defp header(element), do: {Document.text(element, "name"), Document.text(element, "value")}

  defp data(nil), do: nil

  defp data(element) do
    %{
      content_type: Document.text(element, "content-type"),
      filepath: Document.text(element, "filepath"),
      # A request may rewrite names inside the file it sends —
      # `<substitute>` maps a placeholder to a value, which may itself
      # be a substitution.
      substitutions:
        for substitute <- Document.children(element, "substitute") do
          {Document.text(substitute, "name"), Document.text(substitute, "value")}
        end
    }
  end

  # An argument may carry several values — `propfindItems` takes a list
  # of properties — so they are collected rather than overwritten.
  defp verify(element) do
    args =
      for argument <- Document.children(element, "arg"), into: %{} do
        values = for value <- Document.children(argument, "value"), do: String.trim(value.text)
        {Document.text(argument, "name"), values}
      end

    %Verify{
      callback: Document.text(element, "callback"),
      args: args,
      features: features(element, "require-feature"),
      excluded: features(element, "exclude-feature")
    }
  end

  # These feed a value out of one response and into a later request,
  # which is why a scenario using them cannot be run request-by-request
  # without carrying state. Each becomes `{kind, argument, variable}`,
  # or `{:unsupported, name}` for the ones the runner cannot extract.
  @grabbers ~w(graburi grabcount grabheader grabproperty grabelement grabjson
               grabcalproperty grabcalparameter)

  defp grabs(element) do
    for child <- element.children,
        {_namespace, local} = child.name,
        local in @grabbers,
        do: grab(local, child)
  end

  # `graburi` and `grabcount` name their variable directly as text; the
  # rest carry it in a `<variable>` child alongside what to extract.
  defp grab("graburi", element), do: {:uri, nil, String.trim(element.text)}
  defp grab("grabcount", element), do: {:count, nil, String.trim(element.text)}

  defp grab("grabheader", element),
    do: {:header, Document.text(element, "name"), variable(element)}

  defp grab("grabproperty", element),
    do: {:property, Document.text(element, "property"), variable(element)}

  defp grab("grabelement", element),
    do: {:element, Document.text(element, "name"), variable(element)}

  defp grab("grabcalproperty", element),
    do: {:calendar_property, Document.text(element, "name"), variable(element)}

  defp grab("grabcalparameter", element),
    do: {:calendar_parameter, Document.text(element, "name"), variable(element)}

  defp grab(other, _element), do: {:unsupported, other, nil}

  defp variable(element) do
    case Document.child(element, "variable") do
      nil -> nil
      found -> String.trim(found.text)
    end
  end

  defp features(element, name) do
    case Document.child(element, name) do
      nil -> []
      found -> for child <- Document.children(found, "feature"), do: String.trim(child.text)
    end
  end

  defp yes?(element, attribute), do: Map.get(element.attributes, attribute) == "yes"
end
