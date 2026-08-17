defmodule MCP.TestSupport.TestServer do
  @moduledoc "Kernel test fixture server aggregating the fixture tools and resources."

  use MCP.Server,
    name: "test-server",
    version: "9.9.9",
    tools: [
      MCP.TestSupport.EchoTool,
      MCP.TestSupport.SecretTool,
      MCP.TestSupport.HoldTool,
      MCP.TestSupport.FailTool,
      MCP.TestSupport.RaiseTool,
      MCP.TestSupport.DriftTool,
      MCP.TestSupport.UnencodableTool,
      MCP.TestSupport.LinkTool,
      MCP.TestSupport.BadLinkTool
    ],
    resources: [
      MCP.TestSupport.NoteResource,
      MCP.TestSupport.SecretResource,
      MCP.TestSupport.BlobResource,
      MCP.TestSupport.FailResource,
      MCP.TestSupport.HiddenItemResource,
      MCP.TestSupport.UnencodableResource
    ],
    resource_templates: [
      MCP.TestSupport.ItemTemplate,
      MCP.TestSupport.SecretItemTemplate
    ],
    prompts: [
      MCP.TestSupport.ReviewPrompt,
      MCP.TestSupport.SecretPrompt,
      MCP.TestSupport.FailPrompt
    ],
    list_cache: [ttl_ms: 1234, cache_scope: "public"]
end
