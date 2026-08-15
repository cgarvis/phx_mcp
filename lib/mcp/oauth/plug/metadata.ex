defmodule MCP.OAuth.Plug.Metadata do
  @moduledoc """
  RFC 8414 authorization server metadata as a mountable plug, served at
  `/.well-known/oauth-authorization-server`.

  Forwarded, the usual way, from inside a router:

      forward "/.well-known/oauth-authorization-server", MCP.OAuth.Plug.Metadata,
        issuer: MyApp.OAuth.issuer(), scopes: MyApp.OAuth.scope_names()

  Or mounted directly in `endpoint.ex`, ahead of the router, with `mount: :endpoint`:

      plug MCP.OAuth.Plug.Metadata,
        issuer: MyApp.OAuth.issuer(), scopes: MyApp.OAuth.scope_names(), mount: :endpoint

  The endpoint form exists for the same reason as `MCP.Plug.WellKnown`'s:
  `/.well-known/oauth-authorization-server` is a path fixed by RFC 8414, not
  app code, so `forward`ing it from inside a `scope` with any prefix answers
  at the wrong absolute path with no local symptom. See that module's
  moduledoc for the fuller explanation and for why `:mount` has to be an
  explicit option rather than something guessed from `conn`.

  Options:

    * `:issuer` — the exact-match issuer identifier; a string or an `{m, f, a}`
      (required). Every endpoint URL is built from it, not from the request, so
      a document cannot describe an origin other than the issuer's.
    * `:scopes` — `scopes_supported`; a list or an `{m, f, a}` (default `[]`)
    * `:base_path` — the prefix the endpoints are mounted under (default
      `"/oauth"`), so the document names where they actually live
    * `:registration_endpoint` — `true` to advertise `<base_path>/register`,
      or a URL to advertise verbatim. Omitted, the document says nothing about
      registration; set it only where `MCP.OAuth.Plug.Register` is mounted, or
      clients will POST at a 404.
    * `:cimd_supported` — `true` to advertise
      `client_id_metadata_document_supported`. Set it only where the store
      resolves an https `client_id` through `MCP.OAuth.CIMD`, or clients will
      present a URL the authorize endpoint rejects as an unknown client.
    * `:mount`: `:forward` (default) or `:endpoint`. In `:endpoint` mode, a
      request whose `path_info` is not exactly
      `[".well-known", "oauth-authorization-server"]` passes through
      untouched (not halted, not 404'd) instead of being answered, since most
      requests reaching an endpoint plug are not this document at all.
  """

  @behaviour Plug

  import Plug.Conn

  # RFC 8414: fixed by the spec, not derived from any option, and unlike
  # RFC 9728 there is no path-inserted sub-path variant to also match.
  @well_known_path [".well-known", "oauth-authorization-server"]

  @impl Plug
  def init(opts) do
    mount = Keyword.get(opts, :mount, :forward)

    unless mount in [:forward, :endpoint] do
      raise ArgumentError,
            "MCP.OAuth.Plug.Metadata :mount must be :forward or :endpoint, got: #{inspect(mount)}"
    end

    %{
      issuer: Keyword.fetch!(opts, :issuer),
      scopes: Keyword.get(opts, :scopes, []),
      base_path: Keyword.get(opts, :base_path, "/oauth"),
      registration_endpoint: Keyword.get(opts, :registration_endpoint),
      cimd_supported: Keyword.get(opts, :cimd_supported),
      mount: mount
    }
  end

  @impl Plug
  def call(conn, %{mount: :endpoint} = config) do
    if conn.path_info == @well_known_path do
      serve(conn, config)
    else
      conn
    end
  end

  def call(conn, config), do: serve(conn, config)

  defp serve(conn, config) do
    issuer = resolve(config.issuer)
    base = issuer <> config.base_path

    document =
      MCP.OAuth.Metadata.document(issuer,
        scopes: resolve(config.scopes),
        authorization_endpoint: base <> "/authorize",
        token_endpoint: base <> "/token",
        introspection_endpoint: base <> "/introspect",
        revocation_endpoint: base <> "/revoke",
        registration_endpoint: registration_endpoint(config.registration_endpoint, base),
        cimd_supported: resolve(config.cimd_supported)
      )

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(document))
    |> halt()
  end

  defp registration_endpoint(true, base), do: base <> "/register"
  defp registration_endpoint(url, _base) when is_binary(url), do: url
  defp registration_endpoint(_other, _base), do: nil

  defp resolve({m, f, a}), do: apply(m, f, a)
  defp resolve(value), do: value
end
