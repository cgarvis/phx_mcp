defmodule MCP.TestSupport.FailPrompt do
  @moduledoc "Kernel test fixture: prompt whose get always fails."

  use MCP.Prompt, name: "fail-prompt", scopes: []

  @impl true
  def description, do: "Always fails"

  @impl true
  def get(_args, _ctx), do: {:error, "prompt backend down"}
end
