defmodule MCP.TestSupport.FailTool do
  @moduledoc "Kernel test fixture: always returns a tool execution error."

  use MCP.Tool, name: "fail", scopes: []

  @impl true
  def description, do: "Always returns an execution error"

  @impl true
  def call(_args, _ctx), do: {:error, "boom", "It broke"}
end
