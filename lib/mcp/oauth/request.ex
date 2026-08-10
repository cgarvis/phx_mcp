defmodule MCP.OAuth.Request do
  @moduledoc """
  An authorization request that has already passed every check
  `MCP.OAuth.prepare/2` makes, but for which no code exists yet.

  Splitting prepare from grant is what makes a consent screen possible. The
  request is built once from the query, survives the round trip out to the
  resource owner and back, and `MCP.OAuth.grant/3` mints against these
  fields — never against whatever the approval POST happened to carry.
  """

  @enforce_keys [:client, :redirect_uri, :scope, :params]
  defstruct [:client, :redirect_uri, :scope, :params]

  @type t :: %__MODULE__{
          client: MCP.OAuth.Client.t(),
          redirect_uri: String.t(),
          scope: String.t(),
          params: %{optional(String.t()) => String.t()}
        }

  @doc "The scopes this request would grant, as a list."
  @spec scopes(t()) :: [String.t()]
  def scopes(%__MODULE__{scope: scope}), do: String.split(scope, " ", trim: true)
end
