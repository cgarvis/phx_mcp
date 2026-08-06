defmodule MCP.TestSupport.ReviewPrompt do
  @moduledoc "Kernel test fixture: public prompt with required and optional arguments."

  use MCP.Prompt, name: "review", scopes: []

  @impl true
  def description, do: "Ask for a review"

  arguments do
    field :code, :string, required: true, description: "The code to review"
    field :tone, :string, description: "Review tone", default: "kind"
  end

  @impl true
  def get(%__MODULE__{code: code, tone: tone}, _ctx) do
    {:ok,
     [
       {:assistant, "I review in a #{tone} tone."},
       {:user, "Please review:\n#{code}"}
     ]}
  end
end
