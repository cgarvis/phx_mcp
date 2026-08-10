defmodule MCP.Name do
  @moduledoc """
  Compile-time validation of tool and prompt names.

  The MCP spec puts no character restrictions on a `name`, but the clients that
  matter do. Anthropic's connector layer accepts only `[A-Za-z0-9_-]`, and a
  name outside that set is not an error the server ever sees: the client
  silently drops the tool and tells the user it has "tools with unsupported
  names". A dotted namespace like `biomarkers.get` therefore compiles, serves,
  and passes every server-side test while being invisible in Claude Desktop.

  Validating at compile time is the only layer that catches it, since nothing
  downstream reports the rejection back to us.
  """

  @pattern ~r/\A[A-Za-z0-9_-]{1,128}\z/

  @doc """
  Returns `name` if it is a legal MCP client-facing name, or raises.

  `kind` names the caller (`"MCP.Tool"`, `"MCP.Prompt"`) for the error message.
  """
  def validate!(name, kind) when is_binary(name) do
    if Regex.match?(@pattern, name) do
      name
    else
      raise ArgumentError,
            "invalid #{kind} name #{inspect(name)}: names may contain only letters, digits, " <>
              "underscore, and hyphen (1-128 chars). Anthropic clients silently exclude tools " <>
              "with any other character -- use #{inspect(suggest(name))} instead."
    end
  end

  def validate!(name, kind) do
    raise ArgumentError, "invalid #{kind} name #{inspect(name)}: expected a string"
  end

  defp suggest(name), do: String.replace(name, ~r/[^A-Za-z0-9_-]/, "_")
end
