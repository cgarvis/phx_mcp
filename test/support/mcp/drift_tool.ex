defmodule MCP.TestSupport.DriftTool do
  @moduledoc "Kernel test fixture: returns a result that violates its own outputSchema."

  use MCP.Tool, name: "drift", scopes: []

  @impl true
  def description, do: "Declares an integer result and returns a string"

  output do
    field :count, :integer, required: true
  end

  @impl true
  def call(_args, _ctx), do: {:ok, %{count: "not an integer"}}
end
