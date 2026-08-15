defmodule MCP.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :mcp,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      name: "MCP",
      description: description()
    ]
  end

  # No supervision tree: the library starts nothing. A host mounts its plugs
  # and supplies its own store, auth adapter, and resource owner.
  def application do
    [extra_applications: [:logger, :crypto]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:plug, "~> 1.16"},
      {:plug_crypto, "~> 2.1"},
      {:jason, "~> 1.2"},
      {:telemetry, "~> 1.0"},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end

  defp description do
    "Model Context Protocol server kernel for Plug applications, with a built-in OAuth 2.1 authorization server."
  end

  defp docs do
    [
      main: "MCP",
      extras: ["README.md"],
      groups_for_modules: [
        Definitions: [MCP.Tool, MCP.Resource, MCP.ResourceTemplate, MCP.Prompt, MCP.Server],
        Transport: [MCP.Plug, MCP.Plug.WellKnown, MCP.RPC, MCP.RPC.Request, MCP.Legacy],
        Authentication: [MCP.Auth, MCP.Auth.OAuth, MCP.Auth.Static, MCP.Context],
        "OAuth server": [
          MCP.OAuth,
          MCP.OAuth.Client,
          MCP.OAuth.Code,
          MCP.OAuth.Consent,
          MCP.OAuth.Metadata,
          MCP.OAuth.PKCE,
          MCP.OAuth.Registration,
          MCP.OAuth.Request,
          MCP.OAuth.ResourceOwner,
          MCP.OAuth.Secret,
          MCP.OAuth.Store,
          MCP.OAuth.Store.Memory,
          MCP.OAuth.Token
        ],
        "OAuth endpoints": [
          MCP.OAuth.Plug.Authorize,
          MCP.OAuth.Plug.Metadata,
          MCP.OAuth.Plug.Register,
          MCP.OAuth.Plug.Token
        ]
      ]
    ]
  end
end
