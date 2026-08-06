defmodule MCP.TestSupport.GoneError do
  @moduledoc "Kernel test fixture: exception carrying a 404 plug_status."

  defexception message: "object vanished", plug_status: :not_found
end
