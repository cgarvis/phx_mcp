defmodule MCP.TestSupport.FailResource do
  @moduledoc "Kernel test fixture: read always errors; also exercises a nil MIME type."

  use MCP.Resource, uri: "test://fail", name: "fail-doc", scopes: []

  @impl true
  def description, do: "Always fails to read"

  @impl true
  def read(_ctx), do: {:error, "backend down"}
end
