defmodule MCP.Context do
  @moduledoc """
  Per-request caller identity: the authenticated principal, its granted scopes,
  the client identity self-reported in `_meta` (display/logging only), and the
  client capabilities declared in `_meta`.

  Capabilities gate what a server may ask the client to do: an `inputRequests`
  entry for a capability the client never declared is refused with -32021.

  `assigns` is the host app's own per-request data, in the sense
  `Plug.Conn.assigns` is: the kernel never reads it. An `MCP.Auth` adapter
  populates it while it is already resolving the caller, and handlers read it
  back. That is the seam for anything the app needs on every call but the
  protocol has no opinion about -- a loaded user record, a tenant, a request
  id -- without widening `principal`, which is published to clients.
  """

  defstruct principal: nil, scopes: [], client: nil, capabilities: %{}, assigns: %{}

  @type t :: %__MODULE__{
          principal: term(),
          scopes: [String.t()],
          client: map() | nil,
          capabilities: map(),
          assigns: map()
        }

  @doc "True when the client declared the named capability (`\"elicitation\"`, `\"sampling\"`, `\"roots\"`)."
  def capable?(%__MODULE__{capabilities: capabilities}, capability)
      when is_map(capabilities) and is_binary(capability) do
    Map.has_key?(capabilities, capability)
  end

  def capable?(_ctx, _capability), do: false
end
