defmodule MCP.RPC.Request do
  @moduledoc "A parsed JSON-RPC request. `meta` is the raw `_meta` map from params."

  @enforce_keys [:id, :method]
  defstruct [:id, :method, params: %{}, meta: %{}]

  @type t :: %__MODULE__{
          id: String.t() | integer(),
          method: String.t(),
          params: map(),
          meta: map()
        }
end
