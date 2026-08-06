defmodule MCP.TestSupport.SecretPrompt do
  @moduledoc "Kernel test fixture: scope-gated prompt returning a raw message map."

  use MCP.Prompt, name: "secret-brief", scopes: ["secret:read"]

  @impl true
  def description, do: "Brief on the secret"

  @impl true
  def get(_args, _ctx) do
    {:ok,
     [
       %{
         "role" => "user",
         "content" => %{
           "type" => "resource_link",
           "uri" => "test://secret",
           "name" => "secret-doc"
         }
       }
     ]}
  end
end
