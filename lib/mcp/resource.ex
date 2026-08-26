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
    * `{:ok, content, mime}` — any of the above, served with `mime` instead
      of the module's declared `mime_type()` for this one response; `nil`
      falls back to the declared type, same as omitting the third element.
      This is for a resource whose real type isn't known until the object
      is read — see `MCP.ResourceTemplate` for the motivating example, a
      stored file typed by its own extension. It has no effect on
      `resources/list`, which always advertises the module's declared type.
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

  `cache_scope:` and `ttl_ms:` override the server-level `list_cache` default
  from `MCP.Server` for this resource's own `resources/read` response only —
  every other resource still gets the server default. `"public"` means the
  response may be cached and re-served across different callers, so it is
  only ever correct for data that is identical for everyone: no PHI, no
  per-member content.
  """

  @type content :: binary | {:blob, binary} | map

  @callback uri() :: String.t()
  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback mime_type() :: String.t() | nil
  @callback scopes() :: [String.t()]
  @callback title() :: String.t() | nil
  @callback annotations() :: map() | nil
  @callback cache_scope() :: String.t() | nil
  @callback ttl_ms() :: pos_integer() | nil
  @callback read(ctx :: MCP.Context.t()) ::
              {:ok, content}
              | {:ok, content, String.t() | nil}
              | {:error, :not_found | String.t()}

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @behaviour MCP.Resource

      opts =
        Keyword.validate!(opts, [
          :uri,
          :name,
          :mime_type,
          :title,
          :annotations,
          :cache_scope,
          :ttl_ms,
          scopes: []
        ])

      @mcp_resource_uri Keyword.fetch!(opts, :uri)
      @mcp_resource_name Keyword.fetch!(opts, :name)
      @mcp_resource_mime Keyword.get(opts, :mime_type)
      @mcp_resource_scopes Keyword.fetch!(opts, :scopes)
      @mcp_resource_title Keyword.get(opts, :title)
      @mcp_resource_annotations MCP.Annotations.resource!(Keyword.get(opts, :annotations))
      @mcp_resource_cache_scope MCP.Resource.__validate_cache_scope__(
                                  Keyword.get(opts, :cache_scope)
                                )
      @mcp_resource_ttl_ms MCP.Resource.__validate_ttl_ms__(Keyword.get(opts, :ttl_ms))

      @impl MCP.Resource
      def uri, do: @mcp_resource_uri

      @impl MCP.Resource
      def name, do: @mcp_resource_name

      @impl MCP.Resource
      def mime_type, do: @mcp_resource_mime

      @impl MCP.Resource
      def scopes, do: @mcp_resource_scopes

      @impl MCP.Resource
      def title, do: @mcp_resource_title

      @impl MCP.Resource
      def annotations, do: @mcp_resource_annotations

      @impl MCP.Resource
      def cache_scope, do: @mcp_resource_cache_scope

      @impl MCP.Resource
      def ttl_ms, do: @mcp_resource_ttl_ms
    end
  end

  @doc false
  def __validate_cache_scope__(nil), do: nil
  def __validate_cache_scope__(scope), do: MCP.Server.validate_cache_scope!(scope)

  @doc false
  def __validate_ttl_ms__(nil), do: nil
  def __validate_ttl_ms__(ttl_ms) when is_integer(ttl_ms) and ttl_ms > 0, do: ttl_ms

  def __validate_ttl_ms__(ttl_ms) do
    raise ArgumentError,
          "invalid MCP.Resource ttl_ms #{inspect(ttl_ms)}, expected a positive integer"
  end
end
