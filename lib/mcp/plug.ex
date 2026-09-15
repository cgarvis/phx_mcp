defmodule MCP.Plug do
  @moduledoc """
  Mountable stateless MCP endpoint: origin check, bearer auth, JSON-RPC parse,
  dispatch.

      forward "/mcp", MCP.Plug, server: MyApp.MCP.Server, auth: {MCP.Auth.Static, []}

  Options:

    * `:server` — a `use MCP.Server` module (required)
    * `:auth` — `{adapter, opts}` implementing `MCP.Auth` (required)
    * `:allowed_origins` — browser origins permitted to call this endpoint,
      or `:any`. Defaults to `[]`: a request carrying an `Origin` header is
      rejected with 403, while non-browser callers (which send none) pass.
      This is the spec's DNS-rebinding defense.
    * `:allow_anonymous` — serve a caller that presents no `Authorization`
      header at all, with an empty `MCP.Context` (no principal, no scopes),
      instead of 401. Default `false`. A *present* token that fails
      verification still 401s: a bad credential is an error, not an anonymous
      caller. Turn this on only when the server registers something with
      `scopes: []`, since scope filtering is then the only thing standing
      between an anonymous caller and every other tool and resource.
    * `:handle_ttl_ms` — MRTR handle lifetime, default 10 minutes

  The `Mcp-Method`/`Mcp-Name` routing headers must agree with the body; a
  mismatch is `-32020` with HTTP 400, because infrastructure routes on those
  headers and a disagreement means something upstream sees a different call
  than the body describes.

  Emits `[:mcp, :request, :start | :stop | :exception]` telemetry; see
  `MCP.Telemetry`.
  """

  @behaviour Plug

  # Long enough for any identifier format in real use (a UUID is 36 bytes),
  # short enough that a host tagging metrics with it cannot be handed a
  # multi-kilobyte label.
  @max_session_id_bytes 128

  import Plug.Conn

  alias MCP.RPC

  @impl Plug
  def init(opts) do
    %{
      server: Keyword.fetch!(opts, :server),
      auth: Keyword.fetch!(opts, :auth),
      allowed_origins: Keyword.get(opts, :allowed_origins, []),
      allow_anonymous: Keyword.get(opts, :allow_anonymous, false),
      handle_ttl_ms: Keyword.get(opts, :handle_ttl_ms, MCP.Handle.default_ttl_ms())
    }
  end

  @impl Plug
  def call(%Plug.Conn{path_info: [], method: "POST"} = conn, config) do
    with :ok <- check_origin(conn, config),
         {:ok, ctx} <- authenticate(conn, config) do
      handle_rpc(conn, ctx, config)
    else
      :forbidden -> conn |> respond(403, %{"error" => "origin_not_allowed"}) |> elem(0)
      :unauthorized -> unauthorized(conn, config)
    end
  end

  def call(%Plug.Conn{path_info: []} = conn, _config) do
    conn |> put_resp_header("allow", "POST") |> send_resp(405, "") |> halt()
  end

  def call(conn, _config), do: conn |> send_resp(404, "") |> halt()

  # Browsers always send Origin; a DNS-rebinding attack necessarily comes from one.
  defp check_origin(conn, %{allowed_origins: allowed}) do
    case get_req_header(conn, "origin") do
      [] -> :ok
      [origin] -> if allowed == :any or origin in allowed, do: :ok, else: :forbidden
      _multiple -> :forbidden
    end
  end

  # No header at all is the only anonymous case; a malformed or unverifiable
  # one is a failed credential, which still 401s however the option is set.
  defp authenticate(conn, %{auth: {adapter, opts}} = config) do
    case get_req_header(conn, "authorization") do
      [] -> if config.allow_anonymous, do: {:ok, %MCP.Context{}}, else: :unauthorized
      [header] -> verify_bearer(conn, header, adapter, opts)
      _multiple -> :unauthorized
    end
  end

  defp verify_bearer(conn, header, adapter, opts) do
    with [scheme, token] <- String.split(header, " ", parts: 2),
         true <- String.downcase(scheme) == "bearer",
         {:ok, %MCP.Context{} = ctx} <- adapter.verify(conn, token, opts) do
      {:ok, ctx}
    else
      _ -> :unauthorized
    end
  end

  defp unauthorized(conn, %{auth: {adapter, opts}}) do
    url = adapter.resource_metadata_url(conn, opts)

    conn
    |> put_resp_header("www-authenticate", ~s(Bearer resource_metadata="#{url}"))
    |> respond(401, %{"error" => "invalid_token"})
    |> elem(0)
  end

  defp handle_rpc(conn, ctx, config) do
    case read_json(conn) do
      {:ok, body, conn} ->
        dispatch_body(conn, body, ctx, config)

      {:parse_error, conn} ->
        conn
        |> respond_error(400, nil, {RPC.parse_error(), "Parse error", nil})
        |> elem(0)
    end
  end

  # Pre-2026-07-28 clients. Delete this clause together with lib/mcp/legacy.ex.
  defp dispatch_body(conn, body, ctx, config) do
    case MCP.Legacy.adapt(body, config.server) do
      {:cont, body} -> dispatch_request(conn, body, ctx, config)
      {:halt, status, nil} -> conn |> send_resp(status, "") |> halt()
      {:halt, status, payload} -> conn |> respond(status, payload) |> elem(0)
    end
  end

  defp dispatch_request(conn, body, ctx, config) do
    case RPC.parse(body) do
      {:ok, req} ->
        ctx = %{
          ctx
          | client: client_info(req),
            capabilities: client_capabilities(req),
            protocol_version: declared_version(req),
            session_id: session_id(conn)
        }

        measured(conn, req, ctx, config)

      {:error, error, id} ->
        conn |> respond_error(400, id, error) |> elem(0)
    end
  end

  # `clientInfo` is self-reported and unverified, and the spec does not
  # constrain its shape -- so a caller can send a string, a list, or a number
  # where an object belongs. It is passed through verbatim when it is a map,
  # because a client sending keys we did not anticipate should reach the host
  # intact, but a non-map is dropped rather than forwarded: the struct type,
  # the span contract, and every consumer all say `map() | nil`, and a bare
  # string on the span means the first consumer to write `meta.client["name"]`
  # raises. `:telemetry` responds to a raising handler by detaching it, so that
  # one crafted request would silence every MCP span on the node until restart.
  defp client_info(req) do
    case req.meta[RPC.meta_client_info_key()] do
      client when is_map(client) -> client
      _absent_or_malformed -> nil
    end
  end

  defp client_capabilities(req) do
    case req.meta[RPC.meta_client_capabilities_key()] do
      capabilities when is_map(capabilities) -> capabilities
      _absent -> %{}
    end
  end

  # Read for reporting only, and read before `RPC.negotiate_version/1` has had
  # its say: a request that declares a version we refuse still gets a span, and
  # a span that omitted the version it declared would hide exactly the clients
  # worth finding. A missing or non-string value reports as nil rather than
  # raising -- negotiation, not telemetry, is what rejects it.
  defp declared_version(req) do
    case req.meta[RPC.meta_protocol_version_key()] do
      version when is_binary(version) -> version
      _absent -> nil
    end
  end

  # See MCP.Telemetry for why the chain is this short and why reading a header
  # this revision tells servers to ignore is still the honest thing to do here.
  defp session_id(conn) do
    case header(conn, "mcp-session-id") do
      supplied when is_binary(supplied) ->
        if usable_session_id?(supplied), do: supplied, else: MCP.Telemetry.instance_id()

      nil ->
        MCP.Telemetry.instance_id()
    end
  end

  # The caller chooses this value -- and with `allow_anonymous: true` that
  # caller need not have authenticated at all. The cap bounds how much damage
  # any single value can do to a host that logs or tags with it; it cannot
  # bound how many distinct values arrive, which is the host's problem to
  # bucket. A value that is not plausibly an identifier is treated as no value
  # at all, keeping the field always present rather than emitting garbage.
  defp usable_session_id?(id) do
    byte_size(id) <= @max_session_id_bytes and visible_ascii?(id)
  end

  defp visible_ascii?(<<byte, rest::binary>>) when byte in 0x21..0x7E, do: visible_ascii?(rest)
  defp visible_ascii?(<<>>), do: true
  defp visible_ascii?(_other), do: false

  # The kernel carries the header list so no host has to; MCP.Telemetry owns it
  # because that moduledoc is the published contract for what lands on a span.
  defp vendor_client(conn) do
    Enum.find_value(MCP.Telemetry.vendor_client_headers(), &header(conn, &1))
  end

  # First value only: a repeated header is an upstream that cannot agree with
  # itself, and joining the values would invent a string no client sent.
  defp header(conn, name) do
    case get_req_header(conn, name) do
      [value | _rest] when value != "" -> value
      _none -> nil
    end
  end

  defp measured(conn, req, ctx, config) do
    start = System.monotonic_time()

    metadata = %{
      method: req.method,
      name: body_name(req),
      principal: ctx.principal,
      granted_scopes: ctx.scopes,
      client: ctx.client,
      protocol_version: ctx.protocol_version,
      session_id: ctx.session_id,
      user_agent: header(conn, "user-agent"),
      vendor_client: vendor_client(conn)
    }

    :telemetry.execute([:mcp, :request, :start], %{system_time: System.system_time()}, metadata)

    try do
      run(conn, req, ctx, config)
    rescue
      error ->
        :telemetry.execute(
          [:mcp, :request, :exception],
          %{duration: System.monotonic_time() - start},
          Map.merge(metadata, %{
            kind: :error,
            reason: error,
            stacktrace: __STACKTRACE__
          })
        )

        # The request never completes, so :stop would be a lie; let it raise.
        reraise error, __STACKTRACE__
    else
      {conn, status, error_code} ->
        :telemetry.execute(
          [:mcp, :request, :stop],
          %{duration: System.monotonic_time() - start},
          Map.merge(metadata, %{status: status, error_code: error_code})
        )

        conn
    end
  end

  defp run(conn, req, ctx, %{server: server} = config) do
    case check_transport(conn, req) do
      :ok ->
        dispatch_opts = [
          secret_key_base: conn.secret_key_base,
          handle_ttl_ms: config.handle_ttl_ms
        ]

        case MCP.Server.dispatch(server, req, ctx, dispatch_opts) do
          {:ok, result} ->
            result = RPC.put_server_info(result, server.server_info())
            respond(conn, 200, RPC.result_response(req.id, result))

          {:error, {code, _message, _data} = error} ->
            respond_error(conn, error_status(code), req.id, error)
        end

      {:error, status, error} ->
        respond_error(conn, status, req.id, error)
    end
  end

  # Malformed transport framing is HTTP 400; application errors ride at 200.
  defp check_transport(conn, req) do
    with :ok <- check_header(conn, "mcp-method", "Mcp-Method", req.method),
         :ok <- check_name_header(conn, req) do
      case RPC.negotiate_version(req) do
        :ok -> :ok
        {:error, _reason, error} -> {:error, 400, error}
      end
    end
  end

  defp check_name_header(conn, req) do
    case body_name(req) do
      nil -> :ok
      name -> check_header(conn, "mcp-name", "Mcp-Name", name)
    end
  end

  defp check_header(conn, header, label, expected) do
    case get_req_header(conn, header) do
      [] -> :ok
      [^expected] -> :ok
      [value] -> header_mismatch(label, value, expected)
      # Repeated headers let an upstream router act on a value we never saw.
      values -> header_mismatch(label, Enum.join(values, ", "), expected)
    end
  end

  defp header_mismatch(label, value, expected) do
    {:error, 400,
     {RPC.header_mismatch(),
      "Header mismatch: #{label} header value '#{value}' does not match body value '#{expected}'",
      nil}}
  end

  # The value Mcp-Name mirrors, per method.
  defp body_name(%RPC.Request{method: "tools/call", params: %{"name" => name}})
       when is_binary(name),
       do: name

  defp body_name(%RPC.Request{method: "prompts/get", params: %{"name" => name}})
       when is_binary(name),
       do: name

  defp body_name(%RPC.Request{method: "resources/read", params: %{"uri" => uri}})
       when is_binary(uri),
       do: uri

  defp body_name(_req), do: nil

  # Application errors ride at 200; only these carry a status of their own.
  defp error_status(code) do
    cond do
      code == RPC.method_not_found() -> 404
      code == RPC.missing_required_client_capability() -> 400
      true -> 200
    end
  end

  # Under Phoenix the endpoint has already parsed JSON into body_params;
  # standalone, read and decode here so parse errors surface as -32700.
  defp read_json(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}} = conn) do
    with {:ok, body, conn} <- read_body(conn),
         {:ok, decoded} <- Jason.decode(body) do
      {:ok, decoded, conn}
    else
      _ -> {:parse_error, conn}
    end
  end

  # Plug.Parsers wraps non-object JSON bodies (arrays, scalars) under "_json".
  # Sole key, or a body that legitimately carries a "_json" member unwraps itself.
  defp read_json(%Plug.Conn{body_params: %{"_json" => decoded} = params} = conn)
       when map_size(params) == 1,
       do: {:ok, decoded, conn}

  defp read_json(conn), do: {:ok, conn.body_params, conn}

  defp respond_error(conn, status, id, {code, _message, _data} = error) do
    {conn, ^status, _nil} = respond(conn, status, RPC.error_response(id, error))
    {conn, status, code}
  end

  defp respond(conn, status, payload) do
    conn =
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, RPC.encode!(payload))
      |> halt()

    {conn, status, nil}
  end
end
