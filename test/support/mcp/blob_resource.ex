defmodule MCP.TestSupport.BlobResource do
  @moduledoc "Kernel test fixture: binary resource."

  use MCP.Resource, uri: "test://blob", name: "blob", mime_type: "image/png", scopes: []

  @impl true
  def description, do: "Four bytes of PNG magic"

  @impl true
  def read(_ctx), do: {:ok, {:blob, <<137, 80, 78, 71>>}}
end
