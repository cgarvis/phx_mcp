defmodule MCP.Context do
  @moduledoc """
  Per-request caller identity: the authenticated principal, its granted scopes,
  the client identity self-reported in `_meta` (display/logging only), the
  client capabilities declared in `_meta`, the protocol revision the request
  declared, and an opaque session identifier for correlating requests.

  Capabilities gate what a server may ask the client to do: an `inputRequests`
  entry for a capability the client never declared is refused with -32021.

  `protocol_version` and `session_id` exist for observability, not for
  dispatch: nothing in the kernel branches on either. `protocol_version` is
  the revision string the request declared, copied verbatim before it is
  validated, so a request that goes on to fail version negotiation still
  reports what it claimed. `session_id` is resolved per request by `MCP.Plug`
  and never minted as protocol state -- see `MCP.Telemetry` for the
  resolution order and why this revision leaves so little to resolve from.

  `assigns` is the host app's own per-request data, in the sense
  `Plug.Conn.assigns` is: the kernel never reads it. An `MCP.Auth` adapter
  populates it while it is already resolving the caller, and handlers read it
  back. That is the seam for anything the app needs on every call but the
  protocol has no opinion about -- a loaded user record, a tenant, a request
  id -- without widening `principal`, which is published to clients.
  """

  defstruct principal: nil,
            scopes: [],
            client: nil,
            capabilities: %{},
            protocol_version: nil,
            session_id: nil,
            assigns: %{}

  @type t :: %__MODULE__{
          principal: term(),
          scopes: [String.t()],
          client: map() | nil,
          capabilities: map(),
          protocol_version: String.t() | nil,
          session_id: String.t() | nil,
          assigns: map()
        }

  @doc "True when the client declared the named capability (`\"elicitation\"`, `\"sampling\"`, `\"roots\"`)."
  def capable?(%__MODULE__{capabilities: capabilities}, capability)
      when is_map(capabilities) and is_binary(capability) do
    Map.has_key?(capabilities, capability)
  end

  def capable?(_ctx, _capability), do: false
end
