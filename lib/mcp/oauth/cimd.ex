defmodule MCP.OAuth.CIMD do
  @moduledoc """
  Client ID Metadata Documents: a client identified by an https URL that
  serves its own RFC 7591 metadata, with no registration step
  (draft-ietf-oauth-client-id-metadata-document).

  This is the seam a host app calls from its `c:MCP.OAuth.Store.get_client/1`,
  so `MCP.OAuth` itself stays free of network I/O:

      def get_client(id) do
        if MCP.OAuth.CIMD.client_id?(id) do
          MCP.OAuth.CIMD.fetch_client(id, scopes: MyApp.OAuth.scope_names())
        else
          # ...the app's own table
        end
      end

  A CIMD client gets exactly the shape a self-registered one gets — public,
  PKCE-enforced, `authorization_code` + `refresh_token`, scopes intersected
  with the host's — because `MCP.OAuth.Registration` builds both. Nothing
  vouches for either beyond its own claims, so the consent screen stays the
  gate that matters; `cimd?: true` only lets that screen say *how* the client
  was identified. Control of the https URL is the whole of the client's
  identity, which is why `MCP.OAuth.CIMD.Resolver` treats fetching it as
  hostile input (SSRF, redirects, body size, timeouts).

  A CIMD client is never persisted. It is rebuilt from the document on every
  lookup, cached only for `:cache_ttl_ms`, so revoking one is a matter of
  taking its URL down rather than deleting a row.
  """

  alias MCP.OAuth.CIMD.{Document, Resolver}
  alias MCP.OAuth.{Client, Registration}

  @doc """
  True when `client_id` is a CIMD URL rather than a locally-issued id.

  https and nothing else: the scheme check is what keeps a host's own opaque
  client ids (and any `http://` lookalike) out of the fetch path entirely.
  """
  @spec client_id?(term()) :: boolean()
  def client_id?(client_id) when is_binary(client_id) do
    match?(
      %URI{scheme: "https", host: host} when is_binary(host) and host != "",
      URI.parse(client_id)
    )
  end

  def client_id?(_client_id), do: false

  @doc """
  Resolves `client_id` to a `MCP.OAuth.Client`, fetching its document.

  Options are `MCP.OAuth.CIMD.Resolver`'s, plus `:scopes` — the scopes this
  AS can issue, which the document's requested scope is intersected with
  (default `[]`, i.e. a client that can ask for nothing).

  Every failure collapses to `:error`, matching `c:MCP.OAuth.Store.get_client/1`:
  an unreachable, malformed, or hostile document is an unknown client, and
  the distinction is not the authorization endpoint's to leak.
  """
  @spec fetch_client(String.t(), keyword()) :: {:ok, Client.t()} | :error
  def fetch_client(client_id, opts \\ []) do
    {scopes, resolver_opts} = Keyword.pop(opts, :scopes, [])

    with {:ok, document} <- Resolver.resolve(client_id, resolver_opts),
         {:ok, client} <- build_client(document, scopes) do
      {:ok, client}
    else
      _error -> :error
    end
  end

  @doc """
  Builds a client from an already-fetched `document`.

  Splitting this out keeps the RFC 7591 rules in one place: whatever
  `MCP.OAuth.Registration` refuses at the registration endpoint, a CIMD
  document is refused for too.
  """
  @spec build_client(Document.t(), [String.t()]) :: {:ok, Client.t()} | {:error, term()}
  def build_client(%Document{} = document, scopes) do
    with {:ok, client} <-
           Registration.build(document.metadata, client_id: document.client_id, scopes: scopes) do
      {:ok, %{client | cimd?: true, client_uri: client.client_uri || document.client_id}}
    end
  end
end
