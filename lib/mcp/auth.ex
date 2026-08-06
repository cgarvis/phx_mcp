defmodule MCP.Auth do
  @moduledoc """
  Bearer-token verification seam for `MCP.Plug`.

  Adapters are mounted as `auth: {module, opts}`. A failed `verify/3` yields a
  401 whose `WWW-Authenticate` points at the OAuth protected-resource metadata
  URL from `resource_metadata_url/2`.
  """

  @callback verify(Plug.Conn.t(), token :: String.t(), opts :: keyword()) ::
              {:ok, MCP.Context.t()} | {:error, :invalid_token}

  @callback resource_metadata_url(Plug.Conn.t(), opts :: keyword()) :: String.t()
end
