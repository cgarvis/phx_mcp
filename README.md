# MCP

A Model Context Protocol server kernel for Plug applications, implementing the
2026-07-28 stateless spec (JSON-RPC 2.0 over HTTP POST), with a built-in OAuth
2.1 authorization server.

> **Name pending.** `mcp` is taken on Hex, and the root module namespace is
> being reconsidered before publication. See "Naming" below.

Depends only on `plug`, `plug_crypto`, `jason`, and `:telemetry`. No Ecto, no
Phoenix, no supervision tree, no application callback. Everything stateful is a
seam the host fills.

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

## Telemetry

Two spans, `[:mcp, :request, :*]` (per JSON-RPC request) and
`[:mcp, :handler, :*]` (per tool call, resource read, or prompt get). The
library installs no handlers. See `MCP.Telemetry` for the full event list and
metadata, and `:telemetry.attach_many/4` to consume them.

## Protocol versions

`MCP.Legacy` answers the pre-2026-07-28 `initialize` handshake, which every
shipping client still opens with. It is quarantined in one file so it can be
deleted in one piece once clients catch up.

## Naming

`mcp` is taken on Hex. `MCP.*` is also a poor namespace to publish under: the
BEAM has one global module table, so an app cannot use this library alongside
any other that defines `MCP.Tool`. A rename is pending. The telemetry event
prefix `[:mcp, ...]` names the protocol rather than the library and is expected
to survive it.

## Origin

Extracted from the Moxie application (`moxie-health/moxie`, `web/lib/mcp`) at
`39ba703`, with history. It was written as a library from the start: the
extraction moved 89 files and changed no code.
