defmodule MCP do
  @moduledoc """
  Protocol kernel for the 2026-07-28 stateless MCP spec (JSON-RPC 2.0 over HTTP POST).

  Pure library: no host-app modules, no Ecto, no Phoenix — only Plug, Jason,
  Plug.Crypto, and `:telemetry` — so extraction to a hex package is a file
  move.

  Define tools with `MCP.Tool`, resources with `MCP.Resource` (parameterized
  families with `MCP.ResourceTemplate`), prompts with `MCP.Prompt`, aggregate
  them with `MCP.Server`, and mount the result with `MCP.Plug`:

      forward "/mcp", MCP.Plug, server: MyApp.MCP.Server, auth: {MCP.Auth.Static, []}
  """

  @protocol_version "2026-07-28"

  def protocol_version, do: @protocol_version
  def supported_versions, do: [@protocol_version]
end
