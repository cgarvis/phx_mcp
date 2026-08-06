defmodule MCP.TestSupport.HoldTool do
  @moduledoc "Kernel test fixture: always pauses for input, echoes state on resume."

  use MCP.Tool, name: "hold", scopes: []

  import MCP.Elicitation, only: [form: 2]

  @impl true
  def description, do: "Pauses for input on first call"

  input do
    field :question, :string
  end

  @impl true
  def call(_args, _ctx) do
    request =
      form "Answer?" do
        field :reply, :string, required: true
      end

    {:input_required, %{"answer" => request}, %{step: 1}}
  end

  @impl true
  def resume(state, responses, _ctx), do: {:ok, %{state: state, responses: responses}}
end
