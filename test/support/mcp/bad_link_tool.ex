defmodule MCP.TestSupport.BadLinkTool do
  @moduledoc "Kernel test fixture: returns a resource link with no uri."

  use MCP.Tool, name: "bad_link", scopes: []

  @impl true
  def description, do: "Returns a malformed resource link"

  @impl true
  def call(_args, _ctx), do: {:ok, %{found: 1}, [%{name: "item-42"}]}
end
