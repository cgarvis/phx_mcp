defmodule MCP.Telemetry do
  @moduledoc """
  Telemetry events emitted by the MCP kernel.

  Attach with `:telemetry.attach_many/4`; the kernel never installs handlers of
  its own, so a host app decides what to do with these.

  ## `[:mcp, :request, :start | :stop | :exception]`

  One span per authenticated JSON-RPC request, emitted by `MCP.Plug`.

    * start measurements — `:system_time`
    * stop/exception measurements — `:duration` (native units)
    * metadata — `:method` (the JSON-RPC method), `:name` (tool name, resource
      URI, or prompt name when the request carries one, else `nil`),
      `:principal`, and on stop `:status` (HTTP status) plus `:error_code`
      (the JSON-RPC error code, `nil` on success)
    * exception metadata — `:kind`, `:reason`, `:stacktrace`

  A raise that escapes the handler layer becomes a 500 at the transport, so it
  gets `:exception` and no `:stop`; a span that only ever stopped would leave
  those requests invisible to latency and error dashboards alike.

  Requests rejected before a method is known (disallowed origin, bad token,
  unparseable body) emit no span: there is nothing to attribute them to.

  ## `[:mcp, :handler, :start | :stop | :exception]`

  One span per tool call, resource read, or prompt get, emitted by
  `MCP.Server` around the handler module.

    * start measurements — `:system_time`
    * stop/exception measurements — `:duration` (native units)
    * metadata — `:kind` (`:tool`, `:resource`, `:resource_template`,
      `:prompt`), `:name`, `:principal`, and on stop `:outcome`
    * exception metadata — `:kind_of_error`, `:reason`, `:stacktrace`

  `:outcome` is `:ok`, `:error` (the handler returned an error), `:not_found`
  (a read miss, including a 404-status raise), `:input_required` (a tool asked
  for more input), or `:invalid` (the handler returned an unusable shape).
  A read miss is a normal outcome, so it stops rather than raising an
  exception event; only an unhandled raise emits `:exception`.
  """

  @doc "Every event the kernel emits, for `:telemetry.attach_many/4`."
  def events do
    [
      [:mcp, :request, :start],
      [:mcp, :request, :stop],
      [:mcp, :request, :exception],
      [:mcp, :handler, :start],
      [:mcp, :handler, :stop],
      [:mcp, :handler, :exception]
    ]
  end
end
