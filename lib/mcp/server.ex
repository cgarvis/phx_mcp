defmodule MCP.Server do
  @moduledoc """
  Aggregates `MCP.Tool`, `MCP.Resource`, `MCP.ResourceTemplate`, and
  `MCP.Prompt` modules into a server definition and dispatches the spec
  methods against it.

      defmodule MyApp.MCP.Server do
        use MCP.Server,
          name: "myapp",
          version: "1.0.0",
          tools: [MyApp.MCP.Tools.Greet],
          resources: [MyApp.MCP.Resources.Readme],
          resource_templates: [MyApp.MCP.Resources.Order],
          prompts: [MyApp.MCP.Prompts.CodeReview],
          list_cache: [ttl_ms: 300_000, cache_scope: "private"]
      end

  List payloads and the `server/discover` document are built at compile time;
  scope filtering happens per request. A tool, resource, or prompt the
  caller's scopes don't cover is invisible and yields the same error as an
  unknown one. On `resources/read`, exact resource URIs win over template
  matches.
  """

  require Logger

  alias MCP.RPC

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @mcp_name Keyword.fetch!(opts, :name)
      @mcp_version Keyword.fetch!(opts, :version)
      @mcp_list_cache Keyword.get(opts, :list_cache, [])
      @mcp_ttl_ms Keyword.get(@mcp_list_cache, :ttl_ms, 60_000)
      @mcp_cache_scope MCP.Server.validate_cache_scope!(
                         Keyword.get(@mcp_list_cache, :cache_scope, "private")
                       )
      @mcp_entries MCP.Server.build_entries!(Keyword.get(opts, :tools, []))
      @mcp_resource_entries MCP.Server.build_resource_entries!(Keyword.get(opts, :resources, []))
      @mcp_template_entries MCP.Server.build_template_entries!(
                              Keyword.get(opts, :resource_templates, [])
                            )
      @mcp_prompt_entries MCP.Server.build_prompt_entries!(Keyword.get(opts, :prompts, []))

      def server_info, do: %{"name" => @mcp_name, "version" => @mcp_version}

      def cache_meta, do: %{"ttlMs" => @mcp_ttl_ms, "cacheScope" => @mcp_cache_scope}

      def tool_entries, do: @mcp_entries

      def resource_entries, do: @mcp_resource_entries

      def template_entries, do: @mcp_template_entries

      def prompt_entries, do: @mcp_prompt_entries

      @mcp_discover %{
        "resultType" => "complete",
        "serverInfo" => %{"name" => @mcp_name, "version" => @mcp_version},
        "supportedVersions" => MCP.supported_versions(),
        "capabilities" =>
          MCP.Server.capabilities(
            tools: @mcp_entries != [],
            resources: @mcp_resource_entries != [] or @mcp_template_entries != [],
            prompts: @mcp_prompt_entries != []
          ),
        "ttlMs" => @mcp_ttl_ms,
        "cacheScope" => @mcp_cache_scope
      }

      def discover_payload, do: @mcp_discover
    end
  end

  @doc false
  # A feature the server has nothing registered under is not advertised at all,
  # so a client never spends a round trip listing an empty set. Nothing here
  # pushes notifications or supports subscriptions, and we say so.
  def capabilities(present) do
    [
      {"tools", present[:tools], %{"listChanged" => false}},
      {"resources", present[:resources], %{"listChanged" => false, "subscribe" => false}},
      {"prompts", present[:prompts], %{"listChanged" => false}}
    ]
    |> Enum.filter(fn {_feature, declared?, _payload} -> declared? end)
    |> Map.new(fn {feature, _declared?, payload} -> {feature, payload} end)
  end

  @valid_cache_scopes ["public", "private"]

  @doc false
  def validate_cache_scope!(scope) when scope in @valid_cache_scopes, do: scope

  def validate_cache_scope!(scope) do
    raise ArgumentError,
          "invalid MCP cache_scope #{inspect(scope)}, expected one of #{inspect(@valid_cache_scopes)}"
  end

  @doc false
  def build_entries!(modules) do
    entries =
      Enum.map(modules, fn mod ->
        %{
          module: mod,
          name: mod.name(),
          scopes: mod.scopes(),
          payload:
            put_output_schema(
              %{
                "name" => mod.name(),
                "description" => mod.description(),
                "inputSchema" => mod.input_schema()
              },
              mod.output_schema()
            )
        }
      end)

    names = Enum.map(entries, & &1.name)
    dups = Enum.uniq(names -- Enum.uniq(names))

    if dups != [] do
      raise ArgumentError, "duplicate MCP tool names: #{inspect(dups)}"
    end

    entries
  end

  defp put_output_schema(payload, nil), do: payload
  defp put_output_schema(payload, schema), do: Map.put(payload, "outputSchema", schema)

  @doc false
  def build_resource_entries!(modules) do
    entries =
      Enum.map(modules, fn mod ->
        payload =
          %{"uri" => mod.uri(), "name" => mod.name(), "description" => mod.description()}
          |> put_mime(mod.mime_type())

        %{
          module: mod,
          uri: mod.uri(),
          scopes: mod.scopes(),
          mime_type: mod.mime_type(),
          payload: payload
        }
      end)

    uris = Enum.map(entries, & &1.uri)
    dups = Enum.uniq(uris -- Enum.uniq(uris))

    if dups != [] do
      raise ArgumentError, "duplicate MCP resource URIs: #{inspect(dups)}"
    end

    entries
  end

  @doc false
  def build_template_entries!(modules) do
    entries =
      Enum.map(modules, fn mod ->
        payload =
          %{
            "uriTemplate" => mod.uri_template(),
            "name" => mod.name(),
            "description" => mod.description()
          }
          |> put_mime(mod.mime_type())

        %{
          module: mod,
          template: MCP.URITemplate.compile!(mod.uri_template()),
          scopes: mod.scopes(),
          mime_type: mod.mime_type(),
          payload: payload
        }
      end)

    sources = Enum.map(entries, & &1.template.source)
    dups = Enum.uniq(sources -- Enum.uniq(sources))

    if dups != [] do
      raise ArgumentError, "duplicate MCP resource template URIs: #{inspect(dups)}"
    end

    entries
  end

  @doc false
  def build_prompt_entries!(modules) do
    entries =
      Enum.map(modules, fn mod ->
        %{
          module: mod,
          name: mod.name(),
          scopes: mod.scopes(),
          payload: prompt_payload(mod)
        }
      end)

    names = Enum.map(entries, & &1.name)
    dups = Enum.uniq(names -- Enum.uniq(names))

    if dups != [] do
      raise ArgumentError, "duplicate MCP prompt names: #{inspect(dups)}"
    end

    entries
  end

  defp prompt_payload(mod) do
    base = %{"name" => mod.name(), "description" => mod.description()}

    case Enum.map(mod.__mcp_arguments__(), &argument_payload/1) do
      [] -> base
      args -> Map.put(base, "arguments", args)
    end
  end

  defp argument_payload({name, opts}) do
    %{"name" => to_string(name)}
    |> maybe_put("description", opts[:description])
    |> maybe_put("required", if(opts[:required], do: true))
  end

  defp put_mime(map, mime), do: maybe_put(map, "mimeType", mime)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc """
  Dispatches a parsed request. Returns `{:ok, result}` or `{:error, {code,
  message, data}}` for the transport to wrap.

  `opts` must carry `secret_key_base:` (MRTR handles) and may carry
  `handle_ttl_ms:`.
  """
  def dispatch(server, %RPC.Request{} = req, %MCP.Context{} = ctx, opts \\ []) do
    case req.method do
      "server/discover" -> {:ok, server.discover_payload()}
      "tools/list" -> {:ok, tools_list(server, ctx)}
      "tools/call" -> tools_call(server, req.params, ctx, opts)
      "resources/list" -> {:ok, resources_list(server, ctx)}
      "resources/read" -> resources_read(server, req.params, ctx)
      "resources/templates/list" -> {:ok, templates_list(server, ctx)}
      "prompts/list" -> {:ok, prompts_list(server, ctx)}
      "prompts/get" -> prompts_get(server, req.params, ctx)
      method -> {:error, {RPC.method_not_found(), "Method not found: #{method}", nil}}
    end
  end

  defp tools_list(server, ctx) do
    tools = for entry <- visible(server.tool_entries(), ctx), do: entry.payload

    %{"resultType" => "complete", "tools" => tools}
    |> Map.merge(server.cache_meta())
  end

  defp resources_list(server, ctx) do
    resources = for entry <- visible(server.resource_entries(), ctx), do: entry.payload

    %{"resultType" => "complete", "resources" => resources}
    |> Map.merge(server.cache_meta())
  end

  defp templates_list(server, ctx) do
    templates = for entry <- visible(server.template_entries(), ctx), do: entry.payload

    %{"resultType" => "complete", "resourceTemplates" => templates}
    |> Map.merge(server.cache_meta())
  end

  defp prompts_list(server, ctx) do
    prompts = for entry <- visible(server.prompt_entries(), ctx), do: entry.payload

    %{"resultType" => "complete", "prompts" => prompts}
    |> Map.merge(server.cache_meta())
  end

  defp prompts_get(server, params, ctx) do
    with {:ok, name} <- fetch_prompt_name(params),
         {:ok, entry} <- fetch_visible_prompt(server, name, ctx),
         {:ok, args} <- validate_prompt_args(entry, params["arguments"] || %{}) do
      %{kind: :prompt, name: entry.name}
      |> telemetry_invoke(ctx, fn -> entry.module.get(args, ctx) end)
      |> wrap_get(entry)
    end
  end

  defp fetch_prompt_name(%{"name" => name}) when is_binary(name), do: {:ok, name}

  defp fetch_prompt_name(_params),
    do: {:error, {RPC.invalid_params(), "prompts/get requires a string \"name\"", nil}}

  # Out-of-scope and nonexistent prompts are indistinguishable by design.
  defp fetch_visible_prompt(server, name, ctx) do
    case Enum.find(visible(server.prompt_entries(), ctx), &(&1.name == name)) do
      nil -> {:error, {RPC.invalid_params(), "Unknown prompt: #{name}", nil}}
      entry -> {:ok, entry}
    end
  end

  defp validate_prompt_args(entry, args) when is_map(args) do
    case MCP.Prompt.validate_args(entry.module, args) do
      {:ok, validated} ->
        {:ok, validated}

      {:error, errors} ->
        {:error,
         {RPC.invalid_params(), "Invalid arguments for prompt: #{entry.name}",
          %{"errors" => errors}}}
    end
  end

  defp validate_prompt_args(_entry, _args),
    do: {:error, {RPC.invalid_params(), "arguments must be an object", nil}}

  defp resources_read(server, params, ctx) do
    with {:ok, uri} <- fetch_resource_uri(params) do
      case find_reader(server, uri, ctx) do
        {:ok, {meta, mime, fun}} ->
          meta
          |> telemetry_invoke_read(ctx, fun)
          |> wrap_read(uri, mime, server.cache_meta())

        :error ->
          {:error, {RPC.invalid_params(), "Resource not found", %{"uri" => uri}}}
      end
    end
  end

  defp fetch_resource_uri(%{"uri" => uri}) when is_binary(uri), do: {:ok, uri}

  defp fetch_resource_uri(_params),
    do: {:error, {RPC.invalid_params(), "resources/read requires a string \"uri\"", nil}}

  # Exact URIs beat templates; out-of-scope and nonexistent stay indistinguishable.
  # Precedence is resolved before the scope gate, or a hidden exact resource
  # would fall through to whatever template covers the same URI space.
  defp find_reader(server, uri, ctx) do
    case Enum.find(server.resource_entries(), &(&1.uri == uri)) do
      %{} = entry ->
        if visible?(entry, ctx) do
          {:ok,
           {%{kind: :resource, name: entry.uri}, entry.mime_type,
            fn -> entry.module.read(ctx) end}}
        else
          :error
        end

      nil ->
        server.template_entries()
        |> visible(ctx)
        |> Enum.find_value(:error, fn entry ->
          case MCP.URITemplate.match(entry.template, uri) do
            {:ok, params} ->
              params = template_struct(entry.module, params)

              {:ok,
               {%{kind: :resource_template, name: entry.template.source}, entry.mime_type,
                fn -> entry.module.read(uri, params, ctx) end}}

            :nomatch ->
              nil
          end
        end)
    end
  end

  # Keys are the template's own variables, so the atoms exist from its defstruct.
  defp template_struct(module, params) do
    struct!(module, for({var, value} <- params, do: {String.to_existing_atom(var), value}))
  end

  defp tools_call(server, params, ctx, opts) do
    with {:ok, name} <- fetch_tool_name(params),
         {:ok, entry} <- fetch_visible_entry(server, name, ctx) do
      case params["requestState"] do
        nil -> initial_call(entry, params, ctx, opts)
        handle -> resume_call(entry, handle, params, ctx, opts)
      end
    end
  end

  defp fetch_tool_name(%{"name" => name}) when is_binary(name), do: {:ok, name}

  defp fetch_tool_name(_params),
    do: {:error, {RPC.invalid_params(), "tools/call requires a string \"name\"", nil}}

  # Out-of-scope and nonexistent tools are indistinguishable by design.
  defp fetch_visible_entry(server, name, ctx) do
    case Enum.find(visible(server.tool_entries(), ctx), &(&1.name == name)) do
      nil -> {:error, {RPC.invalid_params(), "Unknown tool: #{name}", nil}}
      entry -> {:ok, entry}
    end
  end

  defp visible(entries, ctx), do: Enum.filter(entries, &visible?(&1, ctx))

  defp visible?(entry, ctx), do: entry.scopes -- ctx.scopes == []

  defp initial_call(entry, params, ctx, opts) do
    args = params["arguments"] || %{}

    with :ok <- ensure_map_args(args),
         {:ok, validated} <- validate_args(entry, args) do
      %{kind: :tool, name: entry.name}
      |> telemetry_invoke(ctx, fn -> entry.module.call(validated, ctx) end)
      |> wrap(entry, ctx, opts)
    end
  end

  defp resume_call(entry, handle, params, ctx, opts) do
    secret = Keyword.fetch!(opts, :secret_key_base)

    case MCP.Handle.verify(secret, handle) do
      {:ok, %{tool: tool, principal: principal, state: state, requests: requested}}
      when tool == entry.name and principal == ctx.principal ->
        # Interactive code loading leaves the module unloaded until first use,
        # so function_exported?/3 alone would deny a tool that defines resume/3.
        if Code.ensure_loaded?(entry.module) and function_exported?(entry.module, :resume, 3) do
          resume_with(entry, state, requested, params, ctx, opts)
        else
          {:error,
           {RPC.invalid_params(), "Tool does not accept input responses: #{entry.name}", nil}}
        end

      {:ok, _other} ->
        {:error, {RPC.invalid_params(), "requestState does not belong to this tool call", nil}}

      {:error, reason} ->
        {:error, {RPC.invalid_params(), "#{reason} requestState", nil}}
    end
  end

  defp resume_with(entry, state, requested, params, ctx, opts) do
    case accepted_content(params["inputResponses"] || %{}, requested) do
      {:ok, content} ->
        %{kind: :tool, name: entry.name}
        |> telemetry_invoke(ctx, fn -> entry.module.resume(state, content, ctx) end)
        |> wrap(entry, ctx, opts)

      {:refused, names} ->
        wrap(
          {:error, "input_declined",
           "Input was declined or cancelled: #{Enum.join(names, ", ")}"},
          entry,
          ctx,
          opts
        )

      {:unknown, names} ->
        {:error,
         {RPC.invalid_params(), "Unrequested input responses: #{Enum.join(names, ", ")}", nil}}

      :invalid ->
        {:error, {RPC.invalid_params(), "inputResponses must be an object", nil}}
    end
  end

  defp ensure_map_args(args) when is_map(args), do: :ok

  defp ensure_map_args(_args),
    do: {:error, {RPC.invalid_params(), "arguments must be an object", nil}}

  defp validate_args(entry, args) do
    case MCP.Tool.validate_args(entry.module, args) do
      {:ok, validated} ->
        {:ok, validated}

      {:error, errors} ->
        {:error,
         {RPC.invalid_params(), "Invalid arguments for tool: #{entry.name}",
          %{"errors" => errors}}}
    end
  end

  defp telemetry_invoke(meta, ctx, fun) do
    span(meta, ctx, fun, fn _exception -> :__mcp_raised__ end)
  end

  # Raises with a 404 plug_status are object-level not-founds, not internal errors.
  defp telemetry_invoke_read(meta, ctx, fun) do
    span(meta, ctx, fun, fn exception ->
      if Plug.Exception.status(exception) == 404,
        do: {:error, :not_found},
        else: :__mcp_raised__
    end)
  end

  # Handler span: [:mcp, :handler, :start | :stop | :exception]. See MCP.Telemetry.
  defp span(meta, ctx, fun, rescue_fun) do
    start = System.monotonic_time()
    metadata = Map.put(meta, :principal, ctx.principal)

    :telemetry.execute([:mcp, :handler, :start], %{system_time: System.system_time()}, metadata)

    try do
      fun.()
    rescue
      exception ->
        case rescue_fun.(exception) do
          :__mcp_raised__ ->
            Logger.error(
              "MCP #{meta.kind} #{meta.name} raised " <>
                Exception.format(:error, exception, __STACKTRACE__)
            )

            :telemetry.execute(
              [:mcp, :handler, :exception],
              %{duration: System.monotonic_time() - start},
              Map.merge(metadata, %{
                kind_of_error: :error,
                reason: exception,
                stacktrace: __STACKTRACE__
              })
            )

            :__mcp_raised__

          result ->
            emit_stop(start, metadata, result)
            result
        end
    else
      result ->
        emit_stop(start, metadata, result)
        result
    end
  end

  defp emit_stop(start, metadata, result) do
    :telemetry.execute(
      [:mcp, :handler, :stop],
      %{duration: System.monotonic_time() - start},
      Map.put(metadata, :outcome, outcome(result))
    )
  end

  defp outcome({:ok, _result}), do: :ok
  defp outcome({:input_required, _requests, _state}), do: :input_required
  defp outcome({:error, :not_found}), do: :not_found
  defp outcome({:error, _message}), do: :error
  defp outcome({:error, _code, _message}), do: :error
  defp outcome(_other), do: :invalid

  defp wrap({:ok, result}, entry, _ctx, _opts) when is_map(result) do
    case MCP.Tool.validate_result(entry.module, result) do
      :ok ->
        encode_result(result, entry)

      # Sending it anyway would break the outputSchema promise, so refuse.
      {:error, errors} ->
        Logger.error(
          "MCP tool #{entry.name} returned a result violating its outputSchema: " <>
            Enum.join(errors, ", ")
        )

        {:error, {RPC.internal_error(), "Internal error", nil}}
    end
  end

  defp wrap({:input_required, requests, state}, entry, ctx, opts) when is_map(requests) do
    case missing_capabilities(requests, ctx) do
      [] ->
        secret = Keyword.fetch!(opts, :secret_key_base)
        ttl = Keyword.get(opts, :handle_ttl_ms, MCP.Handle.default_ttl_ms())
        # Sealing the asked-for names is what lets resume detect a client that
        # answered none of them; the request itself carries no such record.
        sealed = %{
          tool: entry.name,
          principal: ctx.principal,
          state: state,
          requests: Map.keys(requests)
        }

        {:ok,
         %{
           "resultType" => "input_required",
           "inputRequests" => requests,
           "requestState" => MCP.Handle.sign(secret, sealed, ttl)
         }}

      missing ->
        {:error,
         {RPC.missing_required_client_capability(),
          "Client does not support required capabilities: #{Enum.join(missing, ", ")}",
          %{"requiredCapabilities" => Map.new(missing, &{&1, %{}})}}}
    end
  end

  # Execution errors ride in the result (isError: true), not as JSON-RPC errors.
  # No structuredContent: an error payload cannot conform to a declared outputSchema.
  defp wrap({:error, code, message}, _entry, _ctx, _opts) do
    {:ok,
     %{
       "resultType" => "complete",
       "isError" => true,
       "content" => [%{"type" => "text", "text" => "#{code}: #{message}"}]
     }}
  end

  defp wrap(:__mcp_raised__, _entry, _ctx, _opts),
    do: {:error, {RPC.internal_error(), "Internal error", nil}}

  defp wrap(other, entry, _ctx, _opts) do
    Logger.error("MCP tool #{entry.name} returned an invalid result: #{inspect(other)}")
    {:error, {RPC.internal_error(), "Internal error", nil}}
  end

  # A tool without an output block has nothing checking its shape, so encoding
  # is the last place a bad term can surface; it must not escape as a 500.
  defp encode_result(result, entry) do
    case Jason.encode(result) do
      {:ok, encoded} ->
        {:ok,
         %{
           "resultType" => "complete",
           "isError" => false,
           "content" => [%{"type" => "text", "text" => encoded}],
           "structuredContent" => result
         }}

      {:error, error} ->
        Logger.error("MCP tool #{entry.name} returned an unencodable result: #{inspect(error)}")
        {:error, {RPC.internal_error(), "Internal error", nil}}
    end
  end

  # A server may only ask a client for what the client declared it can do.
  # Only accepted responses reach resume/3, unwrapped to their content, so no
  # tool writes the same decline/cancel branch. The walk is over what the
  # handle says was asked, not over what came back, so an unanswered request
  # is a decline rather than a silent omission.
  defp accepted_content(responses, _requested) when not is_map(responses), do: :invalid

  defp accepted_content(responses, requested) do
    case Enum.sort(Map.keys(responses) -- requested) do
      [] -> collect_responses(responses, requested)
      unknown -> {:unknown, unknown}
    end
  end

  defp collect_responses(responses, requested) do
    {accepted, refused} =
      Enum.reduce(requested, {%{}, []}, fn name, {accepted, refused} ->
        case responses[name] do
          %{"action" => "accept"} = response ->
            {Map.put(accepted, name, response_content(response)), refused}

          _absent_or_refused ->
            {accepted, [name | refused]}
        end
      end)

    if refused == [], do: {:ok, accepted}, else: {:refused, Enum.sort(refused)}
  end

  defp response_content(%{"content" => content}) when is_map(content), do: content
  defp response_content(_response), do: %{}

  defp missing_capabilities(requests, ctx) do
    requests
    |> Map.values()
    |> Enum.map(&required_capability(&1["method"]))
    |> Enum.reject(&(is_nil(&1) or MCP.Context.capable?(ctx, &1)))
    |> Enum.uniq()
  end

  defp required_capability("elicitation/create"), do: "elicitation"
  defp required_capability("sampling/createMessage"), do: "sampling"
  defp required_capability("roots/list"), do: "roots"
  defp required_capability(_method), do: nil

  defp wrap_read({:ok, {:blob, binary}}, uri, mime, cache) when is_binary(binary),
    do: contents_result(uri, mime, "blob", Base.encode64(binary), cache)

  defp wrap_read({:ok, text}, uri, mime, cache) when is_binary(text),
    do: contents_result(uri, mime, "text", text, cache)

  defp wrap_read({:ok, map}, uri, mime, cache) when is_map(map) do
    case Jason.encode(map) do
      {:ok, encoded} ->
        contents_result(uri, mime, "text", encoded, cache)

      {:error, error} ->
        Logger.error("MCP resource #{uri} returned an unencodable result: #{inspect(error)}")
        {:error, {RPC.internal_error(), "Internal error", nil}}
    end
  end

  # Object-level denials wear the same error as URIs that match nothing.
  defp wrap_read({:error, :not_found}, uri, _mime, _cache),
    do: {:error, {RPC.invalid_params(), "Resource not found", %{"uri" => uri}}}

  # Read errors are protocol errors: resources have no in-result isError channel.
  defp wrap_read({:error, message}, _uri, _mime, _cache) when is_binary(message),
    do: {:error, {RPC.internal_error(), message, nil}}

  defp wrap_read(:__mcp_raised__, _uri, _mime, _cache),
    do: {:error, {RPC.internal_error(), "Internal error", nil}}

  defp wrap_read(other, uri, _mime, _cache) do
    Logger.error("MCP resource #{uri} returned an invalid result: #{inspect(other)}")
    {:error, {RPC.internal_error(), "Internal error", nil}}
  end

  # ReadResourceResult is a CacheableResult in this revision: ttlMs/cacheScope required.
  defp contents_result(uri, mime, key, value, cache) do
    content = %{"uri" => uri} |> put_mime(mime) |> Map.put(key, value)
    {:ok, Map.merge(%{"resultType" => "complete", "contents" => [content]}, cache)}
  end

  defp wrap_get({:ok, messages}, entry) when is_list(messages) do
    case encode_messages(messages) do
      {:ok, encoded} ->
        {:ok,
         %{
           "resultType" => "complete",
           "description" => entry.payload["description"],
           "messages" => encoded
         }}

      :error ->
        Logger.error("MCP prompt #{entry.name} returned an invalid message")
        {:error, {RPC.internal_error(), "Internal error", nil}}
    end
  end

  # Get errors are protocol errors: prompts have no in-result isError channel.
  defp wrap_get({:error, message}, _entry) when is_binary(message),
    do: {:error, {RPC.internal_error(), message, nil}}

  defp wrap_get(:__mcp_raised__, _entry),
    do: {:error, {RPC.internal_error(), "Internal error", nil}}

  defp wrap_get(other, entry) do
    Logger.error("MCP prompt #{entry.name} returned an invalid result: #{inspect(other)}")
    {:error, {RPC.internal_error(), "Internal error", nil}}
  end

  defp encode_messages(messages) do
    encoded = Enum.map(messages, &encode_message/1)
    if nil in encoded, do: :error, else: {:ok, encoded}
  end

  defp encode_message({:user, text}) when is_binary(text),
    do: %{"role" => "user", "content" => %{"type" => "text", "text" => text}}

  defp encode_message({:assistant, text}) when is_binary(text),
    do: %{"role" => "assistant", "content" => %{"type" => "text", "text" => text}}

  # Raw spec-shaped maps (images, resource links, embedded resources) pass through.
  defp encode_message(%{} = raw), do: raw
  defp encode_message(_other), do: nil
end
