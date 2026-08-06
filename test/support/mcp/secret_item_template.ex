defmodule MCP.TestSupport.SecretItemTemplate do
  @moduledoc "Kernel test fixture: scope-gated text resource template."

  use MCP.ResourceTemplate,
    uri_template: "test://secrets/{id}",
    name: "secret-item",
    mime_type: "text/plain",
    scopes: ["secret:read"]

  @impl true
  def description, do: "A secret item by id"

  @impl true
  def read(_uri, %__MODULE__{id: id}, _ctx), do: {:ok, "classified #{id}"}
end
