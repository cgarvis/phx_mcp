defmodule MCP.TestSupport.EchoTool do
  @moduledoc "Kernel test fixture: one field of every supported type."

  use MCP.Tool, name: "echo", scopes: []

  @impl true
  def description, do: "Echo validated arguments"

  input do
    field :text, :string, required: true, description: "Text to echo"
    field :count, :integer
    field :level, :string, enum: ["low", "high"], default: "low"
    field :loud, :boolean
  end

  @impl true
  def call(%__MODULE__{} = args, _ctx) do
    supplied = args |> Map.from_struct() |> Map.reject(fn {_k, v} -> is_nil(v) end)
    {:ok, %{args: supplied}}
  end
end
