defmodule MCP.ResourceTemplate do
  @moduledoc """
  Behaviour + macro for a parameterized MCP resource family, advertised via
  `resources/templates/list` as an RFC 6570 `uriTemplate`.

      defmodule MyApp.MCP.Resources.Order do
        use MCP.ResourceTemplate,
          uri_template: "myapp://orders/{id}",
          name: "order",
          mime_type: "application/json",
          scopes: ["orders:read"]

        @impl true
        def description, do: "One order by id"

        @impl true
        def read(_uri, %__MODULE__{id: id}, ctx) do
          case MyApp.Orders.fetch(ctx.principal, id) do
            {:ok, order} -> {:ok, Map.take(order, [:id, :status])}
            :error -> {:error, :not_found}
          end
        end
      end

  Clients expand the template themselves and call plain `resources/read` with
  the concrete URI; exact `MCP.Resource` URIs win over template matches.

  The template's variables define a struct on the module, and `read/3`
  receives that struct carrying the percent-decoded values. Every variable is
  populated whenever the URI matched at all, so there are no `nil`s; matching
  `%__MODULE__{}` makes a variable the template does not declare a compile
  error instead of a clause that silently never matches.

  Scopes gate listing and matching, but `read/3` must still check per-object
  access and return `{:error, :not_found}` on failure — the wire error is
  identical to a URI that matches nothing, so the URI space is not an
  existence oracle. Raising an exception with a 404 `Plug.Exception` status
  (`Repo.get!`, or `defexception plug_status: :not_found`) is equivalent.
  Other returns are as `MCP.Resource.read/1`.
  """

  @callback uri_template() :: String.t()
  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback mime_type() :: String.t() | nil
  @callback scopes() :: [String.t()]
  @callback read(uri :: String.t(), params :: struct(), ctx :: MCP.Context.t()) ::
              {:ok, MCP.Resource.content()} | {:error, :not_found | String.t()}

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @behaviour MCP.ResourceTemplate

      opts = Keyword.validate!(opts, [:uri_template, :name, :mime_type, scopes: []])

      @mcp_template_uri Keyword.fetch!(opts, :uri_template)
      @mcp_template_name Keyword.fetch!(opts, :name)
      @mcp_template_mime Keyword.get(opts, :mime_type)
      @mcp_template_scopes Keyword.fetch!(opts, :scopes)

      # Malformed templates fail here, at the definition site.
      @mcp_template_vars MCP.URITemplate.compile!(@mcp_template_uri).vars

      # A matched URI always fills every variable, so all keys are enforced.
      @enforce_keys Enum.map(@mcp_template_vars, &String.to_atom/1)
      defstruct Enum.map(@mcp_template_vars, &String.to_atom/1)

      @impl MCP.ResourceTemplate
      def uri_template, do: @mcp_template_uri

      @impl MCP.ResourceTemplate
      def name, do: @mcp_template_name

      @impl MCP.ResourceTemplate
      def mime_type, do: @mcp_template_mime

      @impl MCP.ResourceTemplate
      def scopes, do: @mcp_template_scopes
    end
  end
end
