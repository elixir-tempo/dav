defmodule Dav.CalDAVTester.Document do
  @moduledoc """
  Reading a vendored CalDAVTester file as XML.

  Every file in the suite carries `<!DOCTYPE ... SYSTEM "...dtd">`, and
  `Dav.Xml.parse/1` refuses those outright: an external DTD is how XML
  external entity attacks get in, and the production parser is handed
  bodies from the network. That refusal is correct and stays.

  These files are not from the network. They are vendored, read-only,
  and reviewed, so the harness strips the declaration and parses what
  is left — rather than the alternative, which would be to weaken the
  parser that faces clients for the benefit of a test.

  """

  alias Dav.Xml

  @doctype ~r/<!DOCTYPE.*?>/s

  @doc """
  Parse a vendored suite file.

  ### Arguments

  * `path` is a file inside `rfc/conformance/caldavtester`.

  ### Returns

  * `{:ok, element}`, the document root; or

  * `{:error, :malformed}`.

  ### Examples

      iex> {:ok, document} = Dav.CalDAVTester.Document.read("rfc/conformance/caldavtester/scripts/tests/CalDAV/options.xml")
      iex> document.name
      {"", "caldavtest"}

  """
  @spec read(Path.t()) :: {:ok, Xml.element()} | {:error, :malformed}
  def read(path) do
    case File.read(path) do
      {:ok, body} -> body |> String.replace(@doctype, "") |> Xml.parse()
      _unreadable -> {:error, :malformed}
    end
  end

  @doc """
  The text of the first child element with this name.

  ### Arguments

  * `element` is a parsed element.

  * `name` is the local name of the child.

  ### Returns

  * The child's text, or `nil` when there is no such child.

  ### Examples

      iex> {:ok, document} = Dav.CalDAVTester.Document.read("rfc/conformance/caldavtester/scripts/tests/CalDAV/options.xml")
      iex> Dav.CalDAVTester.Document.text(document, "description")
      "Test OPTIONS, DAV header behavior"

  """
  @spec text(Xml.element(), String.t()) :: String.t() | nil
  def text(element, name) do
    case child(element, name) do
      nil -> nil
      found -> String.trim(found.text)
    end
  end

  @doc """
  The first child element with this name.

  ### Arguments

  * `element` is a parsed element.

  * `name` is the local name of the child.

  ### Returns

  * The child element, or `nil`.

  ### Examples

      iex> {:ok, document} = Dav.CalDAVTester.Document.read("rfc/conformance/caldavtester/scripts/tests/CalDAV/options.xml")
      iex> Dav.CalDAVTester.Document.child(document, "missing")
      nil

  """
  @spec child(Xml.element(), String.t()) :: Xml.element() | nil
  def child(element, name), do: Enum.find(element.children, &named?(&1, name))

  @doc """
  Every child element with this name.

  ### Arguments

  * `element` is a parsed element.

  * `name` is the local name of the children.

  ### Returns

  * A list of matching child elements, in document order.

  ### Examples

      iex> {:ok, document} = Dav.CalDAVTester.Document.read("rfc/conformance/caldavtester/scripts/tests/CalDAV/options.xml")
      iex> document |> Dav.CalDAVTester.Document.children("test-suite") |> length()
      2

  """
  @spec children(Xml.element(), String.t()) :: [Xml.element()]
  def children(element, name), do: Enum.filter(element.children, &named?(&1, name))

  defp named?(%{name: {_namespace, name}}, name), do: true
  defp named?(_element, _name), do: false
end
