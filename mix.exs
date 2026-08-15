defmodule MCP.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/cgarvis/phx_mcp"

  # The package is `phx_mcp`; the modules are `MCP.*`. Those are independent in
  # Elixir, and the split is conventional: the `plug_crypto` package defines
  # `Plug.Crypto`, not `PlugCrypto`.
  def project do
    [
      app: :phx_mcp,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
      package: package(),
      name: "phx_mcp",
      source_url: @source_url,
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
      # Optional: only MCP.OAuth.CIMD.ReqTransport uses it, and that is one
      # implementation of the MCP.OAuth.CIMD.Transport behaviour. A host on
      # Finch or Tesla supplies its own transport and never pulls Req; a host
      # that does not use CIMD at all needs neither.
      {:req, "~> 0.5", optional: true},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end

  defp description do
    "Model Context Protocol server kernel for Plug applications, with a built-in OAuth 2.1 authorization server."
  end

  defp package do
    [
      name: "phx_mcp",
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url, "Changelog" => @source_url <> "/blob/main/CHANGELOG.md"},
      # .formatter.exs ships deliberately: it is what gives consumers the
      # DSL's locals_without_parens through import_deps: [:phx_mcp].
      files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "MCP",
      extras: ["README.md", "CHANGELOG.md", "LICENSE"],
      source_ref: "v#{@version}",
      groups_for_modules: [
        Definitions: [MCP.Tool, MCP.Resource, MCP.ResourceTemplate, MCP.Prompt, MCP.Server],
        "Client ID Metadata Documents": [
          MCP.OAuth.CIMD,
          MCP.OAuth.CIMD.Cache,
          MCP.OAuth.CIMD.Document,
          MCP.OAuth.CIMD.ReqTransport,
          MCP.OAuth.CIMD.Resolver,
          MCP.OAuth.CIMD.SSRF,
          MCP.OAuth.CIMD.Transport
        ],
        Transport: [MCP.Plug, MCP.Plug.WellKnown, MCP.RPC, MCP.RPC.Request, MCP.Legacy],
        Authentication: [MCP.Auth, MCP.Auth.OAuth, MCP.Auth.Static, MCP.Context],
        Generators: [Mix.Tasks.Mcp.Gen.Tool],
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
