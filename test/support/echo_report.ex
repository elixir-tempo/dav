defmodule Dav.Test.EchoReport do
  @moduledoc """
  A report that reports what it was given.

  Exists to prove the seam: that a handler registered by qualified name
  is found, receives the resolved resource, the raw body, the depth and
  the store's context, and that what it returns becomes the
  `207 Multi-Status`.
  """

  @behaviour Dav.Web.Report

  alias Dav.Web.Resource

  @impl Dav.Web.Report
  def run(%Resource{} = resource, body, depth, _options) do
    if String.contains?(body, "make-it-fail") do
      {:error, :malformed}
    else
      {:ok,
       [
         {Resource.href(resource),
          [
            {"HTTP/1.1 200 OK",
             [
               {{"http://example.test/ns", "saw-depth"}, Integer.to_string(depth)},
               {{"http://example.test/ns", "saw-bytes"}, Integer.to_string(byte_size(body))}
             ]}
          ]}
       ]}
    end
  end
end
