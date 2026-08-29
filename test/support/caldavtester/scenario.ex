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
    @moduledoc "One response check: a verifier callback and its arguments."
    defstruct [:callback, args: %{}]

    @type t :: %__MODULE__{
            callback: String.t(),
            args: %{optional(String.t()) => [String.t()]}
          }
  end

  defmodule Request do
    @moduledoc "One HTTP request in a scenario, with the checks on its response."
    defstruct [
      :method,
      :data,
      uris: [],
      headers: [],
      verifiers: [],
      grabs: [],
      user: nil,
      end_delete?: false
    ]

    @type t :: %__MODULE__{
            method: String.t(),
            data: %{content_type: String.t(), filepath: String.t() | nil} | nil,
            uris: [String.t()],
            headers: [{String.t(), String.t()}],
            verifiers: [Verify.t()],
            grabs: [String.t()],
            user: String.t() | nil,
            end_delete?: boolean()
          }
  end

  defmodule Test do
    @moduledoc "One named test: a sequence of requests that must all pass."
    defstruct [:name, :description, requests: [], ignore?: false]

    @type t :: %__MODULE__{
            name: String.t(),
            description: String.t() | nil,
            requests: [Request.t()],
            ignore?: boolean()
          }
  end

  defmodule Suite do
    @moduledoc "A named group of tests within a scenario."
    defstruct [:name, tests: [], ignore?: false, features: []]

    @type t :: %__MODULE__{
            name: String.t(),
            tests: [Test.t()],
            ignore?: boolean(),
            features: [String.t()]
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
  def tests(%__MODULE__{} = scenario) do
    for suite <- scenario.suites,
        not suite.ignore?,
        test <- suite.tests,
        not test.ignore?,
        do: {suite, test}
  end

  ## --- reading ----------------------------------------------------

  defp scenario(document, path) do
    %__MODULE__{
      path: path,
      description: Document.text(document, "description"),
      features: features(document),
      setup: requests_in(Document.child(document, "start")),
      teardown: requests_in(Document.child(document, "end")),
      suites: Enum.map(Document.children(document, "test-suite"), &suite/1)
    }
  end

  defp suite(element) do
    %Suite{
      name: Map.get(element.attributes, "name", ""),
      ignore?: yes?(element, "ignore"),
      features: features(element),
      tests: Enum.map(Document.children(element, "test"), &test/1)
    }
  end

  defp test(element) do
    %Test{
      name: Map.get(element.attributes, "name", ""),
      description: Document.text(element, "description"),
      ignore?: yes?(element, "ignore"),
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
      verifiers: Enum.map(Document.children(element, "verify"), &verify/1),
      grabs: grabs(element),
      user: Map.get(element.attributes, "user"),
      end_delete?: yes?(element, "end-delete")
    }
  end

  defp header(element), do: {Document.text(element, "name"), Document.text(element, "value")}

  defp data(nil), do: nil

  defp data(element) do
    %{
      content_type: Document.text(element, "content-type"),
      filepath: Document.text(element, "filepath")
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

    %Verify{callback: Document.text(element, "callback"), args: args}
  end

  # Recorded, not acted on: these feed a value out of one response and
  # into a later request. A scenario that needs one cannot be run
  # faithfully yet, and saying so is better than half-running it.
  @grabbers ~w(graburi grabcount grabheader grabproperty grabelement grabjson
               grabcalproperty grabcalparameter)

  defp grabs(element) do
    for child <- element.children,
        {_namespace, local} = child.name,
        local in @grabbers,
        do: local
  end

  defp features(element) do
    case Document.child(element, "require-feature") do
      nil -> []
      found -> for child <- Document.children(found, "feature"), do: String.trim(child.text)
    end
  end

  defp yes?(element, attribute), do: Map.get(element.attributes, attribute) == "yes"
end
