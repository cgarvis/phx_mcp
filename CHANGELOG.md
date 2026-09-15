# Changelog

## Unreleased

### Added

- The request span (`[:mcp, :request, :*]`) gains `:granted_scopes`, `:client`,
  `:protocol_version`, `:session_id`, `:user_agent`, and `:vendor_client`.
  Every one of these was already in hand at the moment the span was emitted
  and simply was not passed on, which left a consumer unable to answer
  questions the kernel already knew the answer to -- which client build is
  responsible for a latency regression, which declared revisions this server is
  refusing, whether two callers issuing the identical request diverge because
  their granted scopes differ. `:granted_scopes` is the caller's own list; `:client` is
  the `_meta` `clientInfo` object verbatim rather than a flattened name and
  version, so a client sending unanticipated keys reaches the host intact --
  but only when it is actually an object. `clientInfo` is unverified and the
  spec does not constrain its shape, and a non-object forwarded under a key
  every type signature calls a map would raise in the first consumer that
  subscripted it, which `:telemetry` punishes by detaching that handler for
  good. A non-object now reports as `nil`.
  `:user_agent` is the raw `User-Agent` request header and `:vendor_client` the
  raw value of the first header in `MCP.Telemetry.vendor_client_headers/0` the
  request carries -- both HTTP-only and self-reported, `nil` when absent. `:protocol_version` is read before negotiation runs, so a
  request declaring a revision this server refuses still reports what it
  declared instead of reporting nothing. Note that it cannot be used to count
  surviving pre-2026-07-28 clients: `MCP.Legacy` stamps this server's own
  revision onto a request that declares none, before the span is built, so
  legacy callers are indistinguishable from current ones on this field.

- The handler span (`[:mcp, :handler, :*]`) gains `:description` and
  `:required_scopes` from the entry being invoked, plus `:client`,
  `:protocol_version`, and `:session_id` carried through from the request.
  The entry fields matter beyond convenience: without them an observer has to
  reach back into the server module by name to recover a description, which
  inverts the layering and goes wrong the moment a name is reused across
  servers or a module is renamed. Neither scope list is called plain
  `:scopes`, deliberately: `:granted_scopes` is about a caller and
  `:required_scopes` about a definition, and since `events/0` invites a host
  to attach all six events with one `:telemetry.attach_many/4`, a shared key
  would let one handler tagging on `metadata[:scopes]` blend two unrelated
  lists into one meaningless dimension with nothing raising. Ecto sets the
  precedent in this project's own dependency tree, qualifying every instance
  of a repeated concept (`query_time`, `queue_time`, `decode_time`,
  `idle_time`) rather than leaving one bare.

  A caller-supplied `:session_id` is accepted only if it is at most 128 bytes
  of visible ASCII, which bounds what any single value can do to a host that
  logs or tags with it. It does not bound how many *distinct* values arrive, so
  `:session_id` must not be used directly as a metric label -- see
  `MCP.Telemetry` for what it is safe for.

- `:session_id`, on both spans, an opaque correlation label resolved per
  request: a client-supplied `Mcp-Session-Id` header if there is one,
  otherwise `MCP.Telemetry.instance_id/0`. This is resolution only -- no
  session lifecycle, no session state, nothing minted, echoed, or stored. The
  chain is short because the 2026-07-28 revision is stateless by design and
  defines no conversation or session key anywhere in `_meta`; reading the
  legacy header at all is justified in `MCP.Telemetry`, along with an honest
  account of how weak the instance-id fallback is.

- `MCP.Telemetry.vendor_client_headers/0`, the ordered list of request headers
  checked to populate `:vendor_client`, first match winning. The kernel carries
  this list rather than exposing it as a plug option: these names are facts
  about how particular clients behave on the wire, the same kind of fact as a
  user-agent database, and every host mounting the endpoint would otherwise
  have to discover and maintain the same list independently. Teaching the
  library a new vendor is a one-line change with no consumer action. A name
  earns a place only when the vendor documents it -- guessing is worse than
  leaving the field nil, since a wrong name is indistinguishable from a caller
  that sent nothing. Today the list holds `x-anthropic-client` alone; OpenAI
  documents no such header, and a ChatGPT connector is identified through
  `:client` and `:user_agent` instead.

- `MCP.Telemetry.instance_id/0`, an opaque random identifier generated on
  first use and stable for the life of the VM, held in `:persistent_term`. It
  is deliberately not derived from the node name, host, or boot time: a
  derived identifier is reproducible by anything that knows the inputs, and
  this value ends up in a host's analytics store where that invites being
  treated as a join key onto the deployment itself.

- `MCP.Server.visible_tools/2`, the scope-filtered tool entries `tools/list`
  would advertise to a given `MCP.Context`. The advertised set is a function
  of the caller, not of the server module alone, so an observer that read
  `server.tool_entries()` instead would report tools the caller can neither
  see nor call. Entries are the kernel's internal shape (`:module`, `:name`,
  `:scopes`, `:payload`); the wire payload is `entry.payload`.

- `MCP.RPC.meta_protocol_version_key/0`, alongside the `clientInfo` and
  `clientCapabilities` accessors that already existed, so nothing outside
  `MCP.RPC` has to restate the `_meta` key as a literal.

- `MCP.Context` gains `:protocol_version` and `:session_id`. Both exist for
  observability and nothing in the kernel branches on either; they sit on the
  context because that is already how per-request caller facts from `_meta`
  reach a handler, and because the handler span needs them.

All of this is additive: no existing metadata key changed name, type, or
meaning, and a consumer attached to 0.2.0 spans keeps working untouched.
Spans still carry no tool arguments, no tool results, no resource bodies, no
prompt arguments, and no request or response payloads -- see the note at the
top of `MCP.Telemetry` for why that is a standing property and not a default
awaiting a flag.

## 0.2.0 — 2026-08-26

### Added

- `c:MCP.Resource.read/1` and `c:MCP.ResourceTemplate.read/3` gain a
  three-element success return, `{:ok, content, mime}`, overriding the
  module's declared `mime_type()` for that one response. A resource template
  serving a family of stored objects -- files by extension, say -- has no
  single real MIME type to declare; previously every object had to be served
  as whatever placeholder `mime_type()` named, or as `nil`, forcing clients
  to discover the encoding by failure. `nil` for the override falls back to
  the declared type, the same as the existing two-element return, so no
  existing resource or template changes. The override is answered only from
  `resources/read`; `resources/list` and `resources/templates/list` keep
  advertising the module's own declared type, which is the family-level
  default. A non-binary, non-`nil` override is the host app's bug and is
  refused as an internal error rather than shipped, the same treatment an
  unencodable result already gets.

- `MCP.URITemplate` gains RFC 6570 Level-2 reserved expansion, `{+var}`: a
  variable that may claim `/` instead of stopping at it, for a family
  addressed by a whole path rather than one segment --
  `croft://{org}/{ws}/files/{+path}` matching a stored file at
  `reports/2026-08-25.md`. It is legal only as a template's final expression;
  a literal or another variable after it raises `ArgumentError` at
  `compile!/1`, since two reserved variables (or one followed by more
  template) would make matching combinatorial over attacker-supplied URIs
  and resolve any ambiguous split by arbitrary greedy-match order rather than
  a rule. The variable's name excludes the leading `+` -- `{+path}` is the
  field `path` on the generated `MCP.ResourceTemplate` struct, same as
  `{path}` would be -- and, because reserved expansion leaves `/` unencoded,
  `%2F` decodes to a literal `/` there too, so `a%2Fb` and `a/b` are
  indistinguishable once matched. Plain `{var}` is unaffected: it still never
  crosses a `/` and still rejects a value that decodes to one.

## 0.1.1 — 2026-08-26

### Added

- `MCP.Tool` input field types `:object` (a bare JSON object) and `:any` (an
  unconstrained JSON value), also legal as array `items:`. Both are leaves,
  not a nested schema language: an argument whose shape is defined by user
  data at runtime -- a workflow's trigger payload, a document store's value,
  a record stream's rows -- had no representable type, and encoding those as
  JSON strings misleads the model, since `inputSchema` is what it reads.

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
