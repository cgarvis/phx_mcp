defmodule MCP.TestSupport.RaiseTool do
  @moduledoc "Kernel test fixture: always raises."

  use MCP.Tool, name: "raise", scopes: []

  @impl true
  def description, do: "Always raises"

  @impl true
  def call(_args, _ctx), do: raise("kaboom")
end
