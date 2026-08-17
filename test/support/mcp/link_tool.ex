defmodule MCP.TestSupport.LinkTool do
  @moduledoc "Kernel test fixture: returns resource links alongside its structured result."

  use MCP.Tool, name: "link", scopes: []

  import MCP.Elicitation, only: [form: 2]

  @impl true
  def description, do: "Returns links to the resources it found"

  input do
    field :hold, :boolean, default: false
  end

  # The paused branch is how the resume path gets links to carry.
  @impl true
  def call(%__MODULE__{hold: true}, _ctx) do
    request =
      form "Which one?" do
        field :reply, :string, required: true
      end

    {:input_required, %{"which" => request}, %{step: 1}}
  end

  def call(%__MODULE__{}, _ctx) do
    {:ok, %{ids: ["42", "43"]}, [link("42"), link("43")]}
  end

  @impl true
  def resume(_state, _responses, _ctx), do: {:ok, %{ids: ["42"]}, [link("42")]}

  # These URIs are MCP.TestSupport.ItemTemplate's, which TestServer serves.
  defp link(id) do
    %{
      uri: "test://items/#{id}",
      name: "item-#{id}",
      title: "Item #{id}",
      description: "Item #{id} as a resource",
      mime_type: "application/json",
      annotations: [audience: [:assistant]]
    }
  end
end
