# Changelog

## 0.1.0 — 2026-08-26

Initial extraction from the Moxie application, where this library was
developed in-tree under `web/lib/mcp`.

### Added

- MCP server kernel for the 2026-07-28 stateless spec: `MCP.Tool`,
  `MCP.Resource`, `MCP.ResourceTemplate`, `MCP.Prompt`, `MCP.Server`,
  and `MCP.Plug`.
- OAuth 2.1 authorization server: authorize, token, introspect, revoke,
  metadata, and RFC 7591 dynamic client registration, behind the
  `MCP.OAuth.Store`, `MCP.OAuth.ResourceOwner`, and `MCP.OAuth.Consent`
  seams.
- Client ID Metadata Document resolution (`MCP.OAuth.CIMD`) with SSRF
  filtering, DNS-rebinding protection, per-hop redirect validation, and a
  streaming response cap.
- `mix mcp.gen.tool` for scaffolding tool modules.
- Telemetry spans on `[:mcp, :request, :*]` and `[:mcp, :handler, :*]`.
- `MCP.Legacy`, answering the pre-2026-07-28 handshake from one deletable
  file.
- `MCP.OAuth.Store.Ecto`, a Postgres-only `MCP.OAuth.Store` generated with
  `use MCP.OAuth.Store.Ecto, repo: MyApp.Repo`, plus its
  `mix mcp.gen.oauth.migration` generator. `ecto_sql` is an optional
  dependency; a host that does not use this adapter pulls nothing new.
- `MCP.Router`: Phoenix router macros. `mcp/2` mounts `MCP.Plug`; `mcp_oauth/2`
  mounts all six OAuth endpoints (authorize, token, introspect, revoke,
  register, metadata), with `:only`/`:except` to mount a subset. No `:phoenix`
  dependency; the macros generate `scope`/`pipe_through`/`forward` calls
  resolved in the caller's own router.
- `MCP.OAuth.Config`: reads authorization-server identity (`:store`,
  `:resource_owner`, `:consent`, `:issuer`, `:scopes`, `:default_resource`)
  from `config :otp_app, MCP.OAuth, ...`, which `mcp_oauth/2` falls back to
  for whichever of those a call site does not pass explicitly. `:issuer`,
  `:scopes`, and `:default_resource` are re-read on every request rather than
  baked in when the router compiles, so a `runtime.exs` override of them
  takes effect.
- `mcp/2` accepts config values of any shape. Options read from
  `config :otp_app, MCP.Plug, ...` are escaped before being spliced into the
  generated `forward`, so an `{m, f, a}`, a map, or a struct nested in an
  adapter's options works. Previously only self-quoting terms survived, and
  anything else raised `invalid quoted expression` in the host's own compile.
- `resource_link` content blocks in tool results. `c:MCP.Tool.call/2` and
  `c:MCP.Tool.resume/3` gain a three-element success tuple,
  `{:ok, map, resource_links}`, whose links are plain snake_case maps validated
  by the new `MCP.ResourceLink` and emitted after the result's text block.
  `structuredContent` is unchanged, and the two-element `{:ok, map}` behaves
  exactly as before.
- - `mount: :endpoint` on `MCP.Plug.WellKnown` and `MCP.OAuth.Plug.Metadata`,
  for mounting `/.well-known/oauth-protected-resource` (RFC 9728) and
  `/.well-known/oauth-authorization-server` (RFC 8414) directly in
  `endpoint.ex`, ahead of the router, where no `scope` prefix can shift them
  off the absolute path their RFC fixes. The existing forwarded mode
  (`mount: :forward`, the default) is unchanged.
