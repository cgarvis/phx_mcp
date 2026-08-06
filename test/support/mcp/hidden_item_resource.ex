defmodule MCP.TestSupport.HiddenItemResource do
  @moduledoc "Kernel test fixture: gated exact resource inside a public template's URI space."

  use MCP.Resource,
    uri: "test://items/hidden",
    name: "hidden-item",
    mime_type: "application/json",
    scopes: ["secret:read"]

  @impl true
  def description, do: "A gated item the public template also covers"

  @impl true
  def read(_ctx), do: {:ok, %{hidden: true}}
end
