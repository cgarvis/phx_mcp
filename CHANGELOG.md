# Changelog

## Unreleased

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
