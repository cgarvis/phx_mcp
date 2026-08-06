defmodule MCP.TestSupport.BoomServer do
  @moduledoc "Kernel test fixture: dispatch raises, exercising the request-level exception span."

  def server_info, do: %{"name" => "boom", "version" => "0.0.0"}

  def discover_payload, do: raise("boom")
end
