defmodule MCP.TestSupport.NoteResource do
  @moduledoc "Kernel test fixture: public text resource."

  use MCP.Resource, uri: "test://note", name: "note", mime_type: "text/plain", scopes: []

  @impl true
  def description, do: "A plain-text note"

  @impl true
  def read(_ctx), do: {:ok, "a note"}
end
