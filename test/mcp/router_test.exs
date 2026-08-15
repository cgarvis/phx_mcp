defmodule MCP.RouterTest do
  use ExUnit.Case, async: true

  # `mcp_oauth/2` resolves :store/:resource_owner/:consent while it expands
  # (see MCP.Router's moduledoc: these are module references, not the kind
  # of thing worth re-reading per request), so this has to be set before the
  # fixture routers below are compiled, not inside `setup` -- module bodies
  # run top to bottom at compile time, and these `defmodule`s come after it
  # in this same file.
  Application.put_env(:mcp_router_test, MCP.OAuth,
    store: MCP.RouterTest.Store,
    resource_owner: MCP.RouterTest.ResourceOwner,
    consent: MCP.RouterTest.Consent,
    issuer: "https://config.test",
    scopes: ["mcp:read"],
    default_resource: "https://config.test/mcp"
  )

  Application.put_env(:mcp_router_test, MCP.Plug,
    auth: {MCP.Auth.Static, key: "s3cret"},
    allow_anonymous: true
  )

  defmodule DefaultRouter do
    use MCP.FakePhoenixRouter
    import MCP.Router

    mcp_oauth("/",
      otp_app: :mcp_router_test,
      browser: :browser,
      api: :api,
      sign_in_path: "/sign-in"
    )

    mcp("/mcp", otp_app: :mcp_router_test, server: MCP.RouterTest.Server)
  end

  defmodule ClientCredentialsOnlyRouter do
    use MCP.FakePhoenixRouter
    import MCP.Router

    mcp_oauth("/", otp_app: :mcp_router_test, api: :api, only: [:token, :metadata])
  end

  defmodule ExceptRouter do
    use MCP.FakePhoenixRouter
    import MCP.Router

    mcp_oauth("/",
      otp_app: :mcp_router_test,
      api: :api,
      except: [:authorize, :register]
    )
  end

  defmodule ExplicitOverridesRouter do
    use MCP.FakePhoenixRouter
    import MCP.Router

    mcp_oauth("/oauth",
      otp_app: :mcp_router_test,
      browser: :browser,
      api: :api,
      store: Other.Store,
      resource_owner: Other.ResourceOwner,
      consent: Other.Consent,
      issuer: "https://explicit.test",
      scopes: ["explicit:scope"],
      default_resource: "https://explicit.test/mcp",
      sign_in_path: "/login",
      registration_endpoint: false
    )
  end

  ## -- no-Phoenix-dependency proof --------------------------------------------

  describe "no Phoenix dependency" do
    test "phx_mcp declares no :phoenix dependency in mix.exs" do
      deps = Mix.Project.config()[:deps]
      refute Enum.any?(deps, fn dep -> elem(dep, 0) == :phoenix end)
    end

    test "MCP.Router itself calls neither scope/2, pipe_through/1, nor forward/2,3 directly" do
      # It generates ASTs containing those calls; it never invokes them. The
      # fixture routers above are the actual proof (they compile at all, and
      # produce the right routes, using only a fake scope/pipe_through/forward
      # defined in test/support -- nothing from this library's own compile-time
      # dependencies).
      refute Code.ensure_loaded?(Phoenix.Router)
    end
  end

  ## -- mcp_oauth/2, defaults resolved from config -----------------------------

  describe "mcp_oauth/2, all six endpoints, identity from config" do
    test "authorize is mounted on the browser pipeline" do
      assert {"/", :browser, "/oauth/authorize", MCP.OAuth.Plug.Authorize, opts} =
               route(DefaultRouter, "/oauth/authorize")

      assert opts[:store] == MCP.RouterTest.Store
      assert opts[:resource_owner] == MCP.RouterTest.ResourceOwner
      assert opts[:consent] == MCP.RouterTest.Consent
      assert opts[:sign_in_path] == "/sign-in"

      assert opts[:default_resource] ==
               {MCP.OAuth.Config, :fetch, [:mcp_router_test, :default_resource]}

      # Not given explicitly and no config default exists for it: absent
      # entirely, so MCP.OAuth.Plug.Authorize's own 600-second default applies.
      refute Keyword.has_key?(opts, :consent_max_age)
    end

    test "the other four endpoints, plus metadata, are mounted on the api pipeline" do
      routes = DefaultRouter.routes()

      api_routes =
        Enum.filter(routes, fn {_scope, pipes, _path, _plug, _opts} -> pipes == :api end)

      assert Enum.map(api_routes, &elem(&1, 2)) == [
               "/.well-known/oauth-authorization-server",
               "/oauth/register",
               "/oauth/token",
               "/oauth/introspect",
               "/oauth/revoke"
             ]

      assert Enum.all?(api_routes, fn {scope, _pipes, _path, _plug, _opts} -> scope == "/" end)
    end

    test "metadata and register share the configured scopes and issuer, unresolved at compile time" do
      {_, _, _, MCP.OAuth.Plug.Metadata, metadata_opts} =
        route(DefaultRouter, "/.well-known/oauth-authorization-server")

      {_, _, _, MCP.OAuth.Plug.Register, register_opts} = route(DefaultRouter, "/oauth/register")

      assert metadata_opts[:issuer] == {MCP.OAuth.Config, :fetch, [:mcp_router_test, :issuer]}
      assert metadata_opts[:scopes] == {MCP.OAuth.Config, :fetch, [:mcp_router_test, :scopes]}
      assert register_opts[:scopes] == {MCP.OAuth.Config, :fetch, [:mcp_router_test, :scopes]}
      assert register_opts[:store] == MCP.RouterTest.Store
      # No rate_limit given and no generic config home for one: absent, not nil.
      refute Keyword.has_key?(register_opts, :rate_limit)
    end

    test "registration_endpoint defaults to true because :register is mounted" do
      {_, _, _, MCP.OAuth.Plug.Metadata, opts} =
        route(DefaultRouter, "/.well-known/oauth-authorization-server")

      assert opts[:registration_endpoint] == true
    end

    test "token and introspect resolve default_resource/issuer the same way" do
      {_, _, _, MCP.OAuth.Plug.Token, token_opts} = route(DefaultRouter, "/oauth/token")
      {_, _, _, MCP.OAuth.Plug.Token, introspect_opts} = route(DefaultRouter, "/oauth/introspect")
      {_, _, _, MCP.OAuth.Plug.Token, revoke_opts} = route(DefaultRouter, "/oauth/revoke")

      assert token_opts[:default_resource] ==
               {MCP.OAuth.Config, :fetch, [:mcp_router_test, :default_resource]}

      assert introspect_opts[:action] == :introspect
      assert introspect_opts[:issuer] == {MCP.OAuth.Config, :fetch, [:mcp_router_test, :issuer]}
      assert revoke_opts[:action] == :revoke
      assert revoke_opts[:store] == MCP.RouterTest.Store
    end
  end

  describe "mcp/2" do
    test "mounts MCP.Plug with :server explicit and everything else from config" do
      assert {nil, nil, "/mcp", MCP.Plug, opts} = route(DefaultRouter, "/mcp")

      assert opts[:server] == MCP.RouterTest.Server
      assert opts[:auth] == {MCP.Auth.Static, key: "s3cret"}
      assert opts[:allow_anonymous] == true
      # Not configured and not given: absent, so MCP.Plug's own defaults apply.
      refute Keyword.has_key?(opts, :allowed_origins)
      refute Keyword.has_key?(opts, :handle_ttl_ms)
    end
  end

  ## -- only:/except: --------------------------------------------------------

  describe "mcp_oauth/2, :only" do
    test "mounts exactly the named endpoints, and :browser is not required" do
      routes = ClientCredentialsOnlyRouter.routes()

      assert Enum.map(routes, &elem(&1, 2)) |> Enum.sort() == [
               "/.well-known/oauth-authorization-server",
               "/oauth/token"
             ]

      refute Enum.any?(routes, fn {_scope, pipes, _path, _plug, _opts} -> pipes == :browser end)
    end

    test "metadata does not advertise registration, since :register was excluded" do
      {_, _, _, MCP.OAuth.Plug.Metadata, opts} =
        route(ClientCredentialsOnlyRouter, "/.well-known/oauth-authorization-server")

      refute Keyword.has_key?(opts, :registration_endpoint)
    end
  end

  describe "mcp_oauth/2, :except" do
    test "mounts everything but the excluded endpoints" do
      routes = ExceptRouter.routes()

      assert Enum.map(routes, &elem(&1, 2)) |> Enum.sort() == [
               "/.well-known/oauth-authorization-server",
               "/oauth/introspect",
               "/oauth/revoke",
               "/oauth/token"
             ]
    end
  end

  ## -- explicit options override config ---------------------------------------

  describe "mcp_oauth/2, explicit options" do
    test "override config wholesale, staying literal rather than becoming MCP.OAuth.Config MFAs" do
      {_, _, _, MCP.OAuth.Plug.Authorize, opts} =
        route(ExplicitOverridesRouter, "/oauth/authorize")

      assert opts[:store] == Other.Store
      assert opts[:resource_owner] == Other.ResourceOwner
      assert opts[:consent] == Other.Consent
      assert opts[:sign_in_path] == "/login"
      assert opts[:default_resource] == "https://explicit.test/mcp"
    end

    test "the mount path itself is honored for every endpoint" do
      assert {"/oauth", :api, "/.well-known/oauth-authorization-server", MCP.OAuth.Plug.Metadata,
              _} =
               route(ExplicitOverridesRouter, "/.well-known/oauth-authorization-server")
    end

    test "an explicit false suppresses the registration_endpoint smart default" do
      {_, _, _, MCP.OAuth.Plug.Metadata, opts} =
        route(ExplicitOverridesRouter, "/.well-known/oauth-authorization-server")

      assert opts[:registration_endpoint] == false
    end
  end

  ## -- compile-time validation -------------------------------------------------

  describe "compile-time errors" do
    test "missing :browser and :api together names both in one error" do
      error =
        assert_compile_raise("""
        import MCP.Router
        mcp_oauth "/", otp_app: :mcp_router_test_errors
        """)

      assert error =~ ":browser"
      assert error =~ ":api"
    end

    test "missing :browser alone, with :authorize mounted, still names it" do
      error =
        assert_compile_raise("""
        import MCP.Router
        mcp_oauth "/", otp_app: :mcp_router_test_errors, api: :api
        """)

      assert error =~ ":browser"
    end

    test ":authorize excluded does not require :browser" do
      refute_compile_raise("""
      import MCP.Router
      mcp_oauth "/", otp_app: :mcp_router_test, api: :api, except: [:authorize]
      """)
    end

    test "no :store, explicit or configured, is a clear error" do
      error =
        assert_compile_raise("""
        import MCP.Router
        mcp_oauth "/", otp_app: :mcp_router_test_no_identity_config, api: :api, only: [:token]
        """)

      assert error =~ ":store"
    end

    test ":metadata alone needs no :store at all" do
      refute_compile_raise("""
      import MCP.Router
      mcp_oauth "/", otp_app: :mcp_router_test_no_identity_config, api: :api, only: [:metadata], issuer: "https://x.test"
      """)
    end

    test ":authorize without :sign_in_path is a clear error" do
      error =
        assert_compile_raise("""
        import MCP.Router
        mcp_oauth "/", otp_app: :mcp_router_test, browser: :browser, api: :api
        """)

      assert error =~ ":sign_in_path"
    end

    test ":authorize and :register together with no resolvable :consent is a clear error" do
      error =
        assert_compile_raise("""
        import MCP.Router
        mcp_oauth "/", otp_app: :mcp_router_test_no_identity_config,
          browser: :browser,
          api: :api,
          store: MCP.RouterTest.Store,
          resource_owner: MCP.RouterTest.ResourceOwner,
          sign_in_path: "/sign-in"
        """)

      assert error =~ ":consent"
    end

    test ":authorize and :register with an explicit :consent compiles fine" do
      refute_compile_raise("""
      import MCP.Router
      mcp_oauth "/", otp_app: :mcp_router_test_no_identity_config,
        browser: :browser,
        api: :api,
        store: MCP.RouterTest.Store,
        resource_owner: MCP.RouterTest.ResourceOwner,
        consent: MCP.RouterTest.Consent,
        sign_in_path: "/sign-in"
      """)
    end

    test "both :only and :except is a clear error" do
      error =
        assert_compile_raise("""
        import MCP.Router
        mcp_oauth "/", otp_app: :mcp_router_test, api: :api, only: [:token], except: [:register]
        """)

      assert error =~ ":only" and error =~ ":except"
    end

    test "an unknown atom in :only is a clear error" do
      error =
        assert_compile_raise("""
        import MCP.Router
        mcp_oauth "/", otp_app: :mcp_router_test, api: :api, only: [:bogus]
        """)

      assert error =~ ":bogus"
    end

    test "mcp/2 without :server is a clear error" do
      error =
        assert_compile_raise("""
        import MCP.Router
        mcp "/mcp", otp_app: :mcp_router_test
        """)

      assert error =~ ":server"
    end
  end

  ## -- helpers -----------------------------------------------------------------

  defp route(router, forward_path) do
    Enum.find(router.routes(), fn {_scope, _pipes, path, _plug, _opts} -> path == forward_path end)
  end

  # Compiles `source` (already using MCP.FakePhoenixRouter as its scope/
  # pipe_through/forward stand-in) as a fresh, uniquely-named module, and
  # returns the raised error's message. Each call gets its own module name so
  # concurrent async tests never redefine one another's module.
  defp assert_compile_raise(body) do
    exception = assert_raise(ArgumentError, fn -> compile_fixture(body) end)
    Exception.message(exception)
  end

  defp refute_compile_raise(body) do
    compile_fixture(body)
    :ok
  end

  defp compile_fixture(body) do
    name = "MCP.RouterTest.Fixture#{System.unique_integer([:positive])}"

    source = """
    defmodule #{name} do
      use MCP.FakePhoenixRouter
      #{body}
    end
    """

    Code.compile_string(source)
    :ok
  end

  describe "config-sourced values that are not self-quoting" do
    # Reported from a host: `Application.get_env/2` returns runtime terms, and
    # `quote` only accepts AST. Atoms, binaries, and 2-element tuples are
    # self-quoting so they survive unescaped, which is why the documented
    # `auth: {MCP.Auth.OAuth, store: MyApp.OAuth.Store}` never showed the bug.
    # Anything else raised "invalid quoted expression" in the *host's* compile,
    # pointing at their router rather than at this macro.
    setup do
      on_exit(fn -> Application.delete_env(:mcp_ast_test, MCP.Plug) end)
    end

    defp compile_router!(name) do
      Code.compile_string("""
      defmodule #{name} do
        use MCP.FakePhoenixRouter
        import MCP.Router

        mcp "/mcp", otp_app: :mcp_ast_test, server: MCP.TestSupport.TestServer
      end
      """)
    end

    test "an {m, f, a} tuple nested in a config value" do
      Application.put_env(:mcp_ast_test, MCP.Plug,
        auth: {MCP.Auth.Static, otp_app: :mcp_ast_test, base_url: {MCP.URL, :join, []}}
      )

      assert [{module, _bin} | _] = compile_router!(:"Elixir.MCPASTTest.MFA")

      assert [{_scope, _pipes, "/mcp", MCP.Plug, opts}] = module.routes()
      assert {MCP.Auth.Static, adapter_opts} = opts[:auth]
      assert adapter_opts[:base_url] == {MCP.URL, :join, []}
    end

    test "a map nested in a config value" do
      Application.put_env(:mcp_ast_test, MCP.Plug,
        auth: {MCP.Auth.Static, tokens: %{"tok" => %{principal: "p", scopes: ["a:read"]}}}
      )

      assert [{module, _bin} | _] = compile_router!(:"Elixir.MCPASTTest.Map")

      assert [{_scope, _pipes, "/mcp", MCP.Plug, opts}] = module.routes()
      assert {MCP.Auth.Static, adapter_opts} = opts[:auth]
      assert adapter_opts[:tokens] == %{"tok" => %{principal: "p", scopes: ["a:read"]}}
    end

    test "a 2-element tuple still round-trips, the shape that always worked" do
      Application.put_env(:mcp_ast_test, MCP.Plug, auth: {MCP.Auth.Static, []})

      assert [{module, _bin} | _] = compile_router!(:"Elixir.MCPASTTest.TwoTuple")

      assert [{_scope, _pipes, "/mcp", MCP.Plug, opts}] = module.routes()
      assert opts[:auth] == {MCP.Auth.Static, []}
    end
  end
end
