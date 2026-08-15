defmodule MCP.OAuth.CIMD.Transport do
  @moduledoc """
  Seam between `MCP.OAuth.CIMD.Resolver` and the actual HTTP fetch, so tests
  can stub the network call while still exercising real DNS resolution +
  SSRF filtering (`MCP.OAuth.CIMD.SSRF.resolve_public_address/1` runs against
  the real hostname regardless of transport — only the connect-and-read-bytes
  step is swappable). Select one with the resolver's `:transport` option.
  """

  @type response :: %{status: integer(), body: binary(), headers: [{String.t(), String.t()}]}

  @callback fetch(uri :: URI.t(), address :: :inet.ip_address(), opts :: keyword()) ::
              {:ok, response()} | {:error, term()}
end
