defmodule MCP.TestSupport.SecretResource do
  @moduledoc "Kernel test fixture: scope-gated JSON resource."

  use MCP.Resource,
    uri: "test://secret",
    name: "secret-doc",
    mime_type: "application/json",
    scopes: ["secret:read"]

  @impl true
  def description, do: "A scope-gated document"

  @impl true
  def read(_ctx), do: {:ok, %{secret: "s3kr3t"}}
end
