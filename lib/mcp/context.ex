defmodule MCP.Context do
  @moduledoc """
  Per-request caller identity: the authenticated principal, its granted scopes,
  the client identity self-reported in `_meta` (display/logging only), and the
  client capabilities declared in `_meta`.

  Capabilities gate what a server may ask the client to do: an `inputRequests`
  entry for a capability the client never declared is refused with -32021.
  """

  defstruct principal: nil, scopes: [], client: nil, capabilities: %{}

  @type t :: %__MODULE__{
          principal: term(),
          scopes: [String.t()],
          client: map() | nil,
          capabilities: map()
        }

  @doc "True when the client declared the named capability (`\"elicitation\"`, `\"sampling\"`, `\"roots\"`)."
  def capable?(%__MODULE__{capabilities: capabilities}, capability)
      when is_map(capabilities) and is_binary(capability) do
    Map.has_key?(capabilities, capability)
  end

  def capable?(_ctx, _capability), do: false
end
