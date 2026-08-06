defmodule MCP.TestSupport.UnencodableTool do
  @moduledoc "Kernel test fixture: declares no outputSchema and returns a term JSON cannot encode."

  use MCP.Tool, name: "unencodable", scopes: []

  @impl true
  def description, do: "Returns a pid"

  @impl true
  def call(_args, _ctx), do: {:ok, %{pid: self()}}
end
