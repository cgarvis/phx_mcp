defmodule MCP.TestSupport.ItemTemplate do
  @moduledoc "Kernel test fixture: public JSON resource template."

  use MCP.ResourceTemplate,
    uri_template: "test://items/{id}",
    name: "item",
    mime_type: "application/json"

  @impl true
  def description, do: "An item by id"

  @impl true
  def read(_uri, %__MODULE__{id: "42"}, _ctx), do: {:ok, %{id: "42", name: "widget"}}
  def read(_uri, %__MODULE__{id: "boom"}, _ctx), do: {:error, "exploded"}
  def read(_uri, %__MODULE__{id: "gone"}, _ctx), do: raise(MCP.TestSupport.GoneError)
  def read(_uri, %__MODULE__{id: "raise"}, _ctx), do: raise("kaboom")
  # Shadowed by a gated exact resource; reaching this is the leak.
  def read(_uri, %__MODULE__{id: "hidden"}, _ctx), do: {:ok, %{leaked: true}}
  def read(_uri, %__MODULE__{}, _ctx), do: {:error, :not_found}
end
