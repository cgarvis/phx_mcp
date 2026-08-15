# phx_mcp

A Model Context Protocol server kernel for Plug applications, implementing the
2026-07-28 stateless spec (JSON-RPC 2.0 over HTTP POST), with a built-in OAuth
2.1 authorization server.

The package is `phx_mcp`; the modules are `MCP.*`. Those are independent in
Elixir, and the split is conventional: the `plug_crypto` package defines
`Plug.Crypto`, not `PlugCrypto`.

```elixir
def deps do
  [{:phx_mcp, "~> 0.1"}]
end
```

Depends on `plug`, `plug_crypto`, `jason`, and `:telemetry`, plus `req` as an
optional dependency used by one swappable transport (see CIMD below). No Ecto,
no Phoenix, no application callback, and nothing it forces you to supervise.
Everything stateful is a seam the host fills.

## Usage

Define tools, resources, and prompts as modules, aggregate them with
`MCP.Server`, and mount the result with `MCP.Plug`:

```elixir
defmodule MyApp.Orders.Get do
  use MCP.Tool, name: "orders_get", scopes: ["orders:read"]

  @description "Fetch one order by id."

  input do
    field :order_id, :string, required: true
  end

  @impl true
  def call(%__MODULE__{order_id: id}, %MCP.Context{assigns: %{scope: scope}}) do
    {:ok, MyApp.Orders.get!(scope, id)}
  end
end

defmodule MyApp.MCP.Server do
  use MCP.Server, name: "my-app", version: "0.1.0", tools: [MyApp.Orders.Get]
end
```

```elixir
# router.ex
forward "/mcp", MCP.Plug,
  server: MyApp.MCP.Server,
  auth: {MCP.Auth.OAuth, store: MyApp.OAuth.Store}

forward "/.well-known/oauth-protected-resource", MCP.Plug.WellKnown,
  otp_app: :my_app,
  base_url: {MyAppWeb.Endpoint, :url, []},
  resource: "/mcp"
```

Tool names are validated at compile time against `[A-Za-z0-9_-]`: Anthropic's
connector layer silently drops anything outside that set, and the server never
sees the rejection. See `MCP.Name`.

## Generators

    mix mcp.gen.tool Orders.Get orders_get order_id:string:required limit:integer \\
      --scope orders:read

    * creating lib/my_app_web/mcp/tools/orders/get.ex

Writes a compiling `MCP.Tool` with its input block and a `call/2` stub, then
tells you the module to register on your `MCP.Server`. The target path is
derived from the host app: `lib/<app>_web/mcp/tools/` when a web directory
exists, otherwise `lib/<app>/mcp/tools/`. Override with `--module` or `--dir`.

Fields are `name:type`, `name:type:required`, or `name:array:element_type`,
where a type is one of `string`, `integer`, `number`, `boolean`, `date`. The
tool name goes through `MCP.Name` at generate time, so a dotted name fails
here rather than compiling into a tool Anthropic clients silently drop.

Generated files compile warning-free under `--warnings-as-errors` and are
already formatted, provided the host has `import_deps: [:phx_mcp]` in its
`.formatter.exs` (which is also what keeps `mix format` from rewriting
`field :code, :string` into `field(:code, :string)`).

The task is `mcp.gen.tool`, not `phx.gen.mcp_tool`: a task's name is its module
path lowercased, so the latter would mean defining `Mix.Tasks.Phx.Gen.McpTool`
inside Phoenix's own namespace, where it lists in `mix help` as though it were
official and breaks the day Phoenix ships the same name.

## Seams

Nothing stateful lives in the library. Each of these is a behaviour the host
implements:

| Behaviour | What the host supplies |
| --- | --- |
| `MCP.Auth` | Bearer-token verification. `MCP.Auth.OAuth` and `MCP.Auth.Static` ship with the library. |
| `MCP.OAuth.Store` | Persistence for clients, codes, and tokens. `MCP.OAuth.Store.Memory` ships for tests. |
| `MCP.OAuth.ResourceOwner` | Who the signed-in user is, for the authorize endpoint. |
| `MCP.OAuth.Consent` | Rendering the consent screen. The library emits no HTML. |

Options that vary per request take an `{module, function, args}` tuple rather
than a value, so `base_url: {MyAppWeb.Endpoint, :url, []}` is just data.
`MCP.OAuth.Plug.Register` takes `rate_limit: {module, function, opts}` on the
same principle.

## OAuth

The library ships a complete authorization server, mounted as four plugs:
`MCP.OAuth.Plug.Authorize`, `.Token`, `.Metadata`, and `.Register` (RFC 7591
dynamic client registration). PKCE is required. Open registration is only safe
behind a consent screen; see `MCP.OAuth.Plug.Authorize`'s `:consent` option.

## Client ID Metadata Documents

`MCP.OAuth.CIMD` resolves an `https://` `client_id` by fetching the RFC 7591
metadata the client serves at that URL, so a client can be identified without
a registration call (draft-ietf-oauth-client-id-metadata-document).

Fetching a URL an unauthenticated caller chose is the whole risk, so
`MCP.OAuth.CIMD.Resolver` is https-only, pins the port, resolves DNS once
through `MCP.OAuth.CIMD.SSRF` and rejects private, loopback, link-local,
multicast, and metadata addresses, then connects to that exact address so a
second lookup cannot rebind to a private one. Redirects are re-validated per
hop rather than followed, the body is capped while streaming, and both connect
and receive are bounded.

Two things here are optional by construction:

  * `MCP.OAuth.CIMD.Transport` is a behaviour. `ReqTransport` is the default
    implementation and the only reason `req` appears in the dependency list at
    all. A host on Finch or Tesla passes `transport:` and never pulls Req.
  * `MCP.OAuth.CIMD.Cache` is a GenServer over ETS, and reads treat a missing
    table as a permanent miss. A host that never starts it still resolves, just
    without caching. Add `MCP.OAuth.CIMD.Cache` to your supervision tree to
    turn it on.

## Telemetry

Two spans, `[:mcp, :request, :*]` (per JSON-RPC request) and
`[:mcp, :handler, :*]` (per tool call, resource read, or prompt get). The
library installs no handlers. See `MCP.Telemetry` for the full event list and
metadata, and `:telemetry.attach_many/4` to consume them.

## Protocol versions

`MCP.Legacy` answers the pre-2026-07-28 `initialize` handshake, which every
shipping client still opens with. It is quarantined in one file so it can be
deleted in one piece once clients catch up.

## A note on the `MCP.*` namespace

The BEAM has one global module table, so two libraries defining `MCP.Tool`
cannot coexist in one app. The other Hex package using this namespace
(`kim-company/mcp`) defines `MCP.Router`, `MCP.Connection`, `MCP.SSE`,
`MCP.Supervisor`, and `MCP.Application`, none of which this library defines, so
there is no collision today. Worth rechecking before a major release.

## Origin

Extracted from the Moxie application (`moxie-health/moxie`, `web/lib/mcp`) at
`39ba703`, with history. It was written as a library from the start: the
extraction moved 89 files and changed no code.
