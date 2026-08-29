defmodule Dav.Web.Method do
  @moduledoc """
  A handler for a method the base protocol does not define.

  The counterpart to `Dav.Web.Report`, for extensions that add a
  *method* rather than a report. CalDAV's `MKCALENDAR` is the only one
  in this family, and it exists so that `Dav.Web` never has to learn
  what a calendar is.

  A registered method is advertised in `Allow` alongside the built-in
  ones, so discovery stays honest without the base knowing what was
  registered or why.

  """

  @typedoc "What the plug resolved for this request."
  @type options :: %{
          required(:store) => module(),
          required(:context) => term(),
          optional(atom()) => term()
        }

  @doc """
  Handle the request.

  ### Arguments

  * `conn` is the request, with its body still unread.

  * `path` is the request path in segments.

  * `options` carries the `:store` and its `:context`. Both are passed
    explicitly rather than left in process state, so a handler is an
    ordinary function of its arguments and can be tested as one.

  ### Returns

  * The `t:Plug.Conn.t/0`, with a response sent.

  """
  @callback call(Plug.Conn.t(), path :: [String.t()], options()) :: Plug.Conn.t()
end
