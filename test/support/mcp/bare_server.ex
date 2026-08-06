defmodule MCP.TestSupport.BareServer do
  @moduledoc "Kernel test fixture: a server with nothing registered."

  use MCP.Server, name: "bare-server", version: "0.0.1"
end
