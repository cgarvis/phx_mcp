defmodule MCP.TestSupport.CIMDTransportStub do
  @moduledoc """
  Test `MCP.OAuth.CIMD.Transport`: canned per-URL responses, stored in the
  calling process's dictionary. Safe under `async: true` because
  `MCP.OAuth.CIMD.Resolver.resolve/2` runs synchronously in the caller (no
  spawned process does the fetch), so each test process gets isolated stub
  state with no shared Agent/GenServer to coordinate.

  DNS resolution (`MCP.OAuth.CIMD.SSRF.resolve_public_address/1`) is NOT
  stubbed -- only the transport is. Tests exercising the happy path
  deliberately use a real, always-resolvable public hostname (example.com) so
  the SSRF-safe resolve-then-pin code path runs for real; only the response
  body is faked.
  """

  @behaviour MCP.OAuth.CIMD.Transport

  @key :cimd_transport_stub_responses

  @spec stub(String.t(), {:ok, MCP.OAuth.CIMD.Transport.response()} | {:error, term()}) :: :ok
  def stub(url, response) do
    Process.put(@key, Map.put(Process.get(@key, %{}), url, response))
    :ok
  end

  @doc "A canned 200 serving `metadata` as this client_id's document."
  @spec stub_document(String.t(), map()) :: :ok
  def stub_document(client_id, metadata \\ %{}) do
    body =
      metadata
      |> Map.put_new("client_id", client_id)
      |> Map.put_new("client_name", "Stub Client")
      |> Map.put_new("redirect_uris", ["https://example.com/callback"])
      |> Jason.encode!()

    stub(client_id, {:ok, %{status: 200, body: body, headers: []}})
  end

  @impl MCP.OAuth.CIMD.Transport
  def fetch(%URI{} = uri, _address, _opts) do
    case Map.fetch(Process.get(@key, %{}), URI.to_string(uri)) do
      {:ok, response} -> response
      :error -> {:error, :fetch_failed}
    end
  end
end
