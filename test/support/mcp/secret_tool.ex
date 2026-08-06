defmodule MCP.TestSupport.SecretTool do
  @moduledoc "Kernel test fixture: scope-gated, no input block, declared output."

  use MCP.Tool, name: "secret", scopes: ["secret:read"]

  @impl true
  def description, do: "Visible only with secret:read"

  output do
    field :secret, :string, required: true
  end

  @impl true
  def call(_args, _ctx), do: {:ok, %{secret: "s3kr3t"}}
end
