defmodule MCP.OAuth.CIMD.Document do
  @moduledoc """
  A fetched Client ID Metadata Document (CIMD), checked for the one property
  that is CIMD's alone: self-reference.

  Per draft-ietf-oauth-client-id-metadata-document, the `client_id` is an
  https URL; fetching that URL returns an RFC 7591-shaped client metadata
  JSON document, self-describing the client — no pre-registration. The
  document's own `client_id` field MUST equal the URL it was fetched from,
  which is what stops one CIMD host from vouching for a different client_id.

  Everything past that check is ordinary RFC 7591 metadata, so `metadata`
  holds the raw map and `MCP.OAuth.CIMD` runs it through
  `MCP.OAuth.Registration` — the same rules, and the same least-privilege
  result, as a client that self-registered at the registration endpoint.
  """

  @enforce_keys [:client_id, :metadata]
  defstruct [:client_id, :metadata, :fetched_at]

  @type t :: %__MODULE__{
          client_id: String.t(),
          metadata: map(),
          fetched_at: DateTime.t() | nil
        }

  @spec parse(url :: String.t(), json :: term()) ::
          {:ok, t()} | {:error, :client_id_mismatch | :invalid_document}
  def parse(url, %{"client_id" => url} = json) do
    {:ok, %__MODULE__{client_id: url, metadata: json, fetched_at: DateTime.utc_now()}}
  end

  def parse(_url, %{"client_id" => _mismatched}), do: {:error, :client_id_mismatch}
  def parse(_url, _json), do: {:error, :invalid_document}
end
