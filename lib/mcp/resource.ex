defmodule MCP.Resource do
  @moduledoc """
  Behaviour + macro for defining an MCP resource: a URI-addressed piece of
  data a client can list (`resources/list`) and read (`resources/read`).

      defmodule MyApp.MCP.Resources.Readme do
        use MCP.Resource,
          uri: "myapp://readme",
          name: "readme",
          mime_type: "text/markdown",
          scopes: []

        @impl true
        def description, do: "The project readme"

        @impl true
        def read(_ctx), do: {:ok, "# Hello"}
      end

  `read/1` returns:

    * `{:ok, text}` — text contents, served with the resource's MIME type
    * `{:ok, {:blob, binary}}` — binary contents, base64-encoded on the wire
    * `{:ok, map}` — JSON-encoded as text contents
    * `{:error, :not_found}` — the same -32602 Resource-not-found error a
      nonexistent URI gets; use it for object-level denials
    * `{:error, message}` — surfaced as a -32603 internal JSON-RPC error

  Raising an exception whose `Plug.Exception` status is 404 is equivalent to
  `{:error, :not_found}` — `Repo.get!` bubbles up as Resource not found the
  way it bubbles up as a 404 in a controller, and any exception can opt in
  with `defexception plug_status: :not_found`.

  A caller whose scopes don't cover `scopes/0` cannot list or read the
  resource; the read error is identical to a nonexistent URI. For URIs with
  variables, see `MCP.ResourceTemplate`.
  """

  @type content :: binary | {:blob, binary} | map

  @callback uri() :: String.t()
  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback mime_type() :: String.t() | nil
  @callback scopes() :: [String.t()]
  @callback read(ctx :: MCP.Context.t()) ::
              {:ok, content} | {:error, :not_found | String.t()}

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @behaviour MCP.Resource

      opts = Keyword.validate!(opts, [:uri, :name, :mime_type, scopes: []])

      @mcp_resource_uri Keyword.fetch!(opts, :uri)
      @mcp_resource_name Keyword.fetch!(opts, :name)
      @mcp_resource_mime Keyword.get(opts, :mime_type)
      @mcp_resource_scopes Keyword.fetch!(opts, :scopes)

      @impl MCP.Resource
      def uri, do: @mcp_resource_uri

      @impl MCP.Resource
      def name, do: @mcp_resource_name

      @impl MCP.Resource
      def mime_type, do: @mcp_resource_mime

      @impl MCP.Resource
      def scopes, do: @mcp_resource_scopes
    end
  end
end
