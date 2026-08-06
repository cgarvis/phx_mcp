defmodule MCP.TestSupport.UnencodableResource do
  @moduledoc "Kernel test fixture: read returns a map JSON cannot encode."

  use MCP.Resource,
    uri: "test://unencodable",
    name: "unencodable-doc",
    mime_type: "application/json",
    scopes: []

  @impl true
  def description, do: "Reads back a pid"

  @impl true
  def read(_ctx), do: {:ok, %{pid: self()}}
end
