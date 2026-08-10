defmodule MCP.OAuth.Plug.Authorize do
  @moduledoc """
  The OAuth authorization endpoint (RFC 6749 §3.1) as a mountable plug.

  Mount it in a pipeline that has already established the application session
  and CSRF protection: the resource owner is resolved from the request's own
  login through the `:resource_owner` module (see `MCP.OAuth.ResourceOwner`),
  and a signed-out request is redirected to `:sign_in_path`.

      forward "/oauth/authorize", MCP.OAuth.Plug.Authorize,
        store: MyApp.OAuth.Store,
        resource_owner: MyApp.OAuth.ResourceOwner,
        consent: MyAppWeb.OAuth.Consent,
        sign_in_path: "/sign-in"

  With `:consent` set, a GET renders the host's screen and only an approving
  POST back to the same path mints a code. Without it, reaching this endpoint
  signed in is itself the grant — safe only where every client was issued by
  hand. Anything mounting `MCP.OAuth.Plug.Register` alongside this MUST set
  `:consent`: open registration without a consent screen lets an attacker
  self-register a client, walk a signed-in member to an authorize URL, and
  receive a code for that member's data. PKCE does not help, because the
  attacker holds the verifier.

  Re-approving an app that was approved before still shows the screen. It is
  the friendlier default to skip it, and most authorization servers do, but
  skipping means a stolen session silently re-grants — the one moment a
  member sees which app is reaching their health data is this screen, and a
  refresh token makes the prompt rare enough that the friction is not worth
  trading for that.

  Options:

    * `:store` — a `MCP.OAuth.Store` (required)
    * `:resource_owner` — a `MCP.OAuth.ResourceOwner` (required)
    * `:sign_in_path` — where a signed-out request is sent (required)
    * `:consent` — a `MCP.OAuth.Consent` rendering the screen (optional)
    * `:consent_max_age` — seconds a rendered screen stays approvable
      (default 600)
    * `:default_resource` — an RFC 8707 resource to bind the code to when the
      request omits one; a string or an `{m, f, a}` resolved per request
  """

  @behaviour Plug

  import Plug.Conn

  # Signed rather than stashed in the session: the grant is self-contained,
  # so a member with two authorize tabs open cannot have one clobber the other.
  @salt "mcp.oauth.consent"

  # Everything an authorization code is derived from, and nothing else, so an
  # attacker cannot pad the signed token with query junk.
  @signed_params ~w(client_id redirect_uri response_type scope state code_challenge
                    code_challenge_method resource)

  @impl Plug
  def init(opts) do
    %{
      store: Keyword.fetch!(opts, :store),
      resource_owner: Keyword.fetch!(opts, :resource_owner),
      sign_in_path: Keyword.fetch!(opts, :sign_in_path),
      consent: Keyword.get(opts, :consent),
      consent_max_age: Keyword.get(opts, :consent_max_age, 600),
      default_resource: Keyword.get(opts, :default_resource)
    }
  end

  @impl Plug
  def call(%{method: "POST"} = conn, %{consent: consent} = config) when not is_nil(consent),
    do: decide(conn, config)

  def call(conn, config), do: ask(fetch_query_params(conn), config)

  ## GET: validate, then either ask or (with no consent screen) grant

  defp ask(conn, config) do
    with {:ok, subject} <- current_owner(conn, config),
         params = put_default_resource(conn.query_params, config.default_resource),
         {:ok, request} <- MCP.OAuth.prepare(config.store, params) do
      case config.consent do
        nil -> finish(conn, MCP.OAuth.grant(config.store, request, subject))
        consent -> prompt(conn, consent, request, subject)
      end
    else
      :error -> redirect(conn, config.sign_in_path)
      {:error, result} -> finish(conn, {:error, result})
    end
  end

  defp prompt(conn, consent, request, subject) do
    grant_token =
      Plug.Crypto.sign(key_base(conn), @salt, %{
        params: Map.take(request.params, @signed_params),
        subject: subject
      })

    conn
    |> consent.render(%{
      client: request.client,
      scopes: MCP.OAuth.Request.scopes(request),
      subject: subject,
      grant_token: grant_token,
      action: conn.request_path
    })
    |> halt()
  end

  ## POST: the answer to a screen we rendered

  defp decide(conn, config) do
    with {:ok, subject} <- current_owner(conn, config),
         {:ok, signed} <- verify_grant(conn, config, conn.body_params["grant_token"]),
         :ok <- same_subject(signed.subject, subject),
         {:ok, request} <- MCP.OAuth.prepare(config.store, signed.params) do
      case conn.body_params["decision"] do
        "approve" -> finish(conn, MCP.OAuth.grant(config.store, request, subject))
        _denied -> finish(conn, MCP.OAuth.deny(request))
      end
    else
      :error -> redirect(conn, config.sign_in_path)
      {:error, {:consent, reason}} -> invalid_request(conn, reason)
      {:error, result} -> finish(conn, {:error, result})
    end
  end

  # A stale or forged token has no redirect target we are willing to trust,
  # so this renders an error rather than bouncing the user agent anywhere.
  defp verify_grant(conn, config, token) when is_binary(token) do
    case Plug.Crypto.verify(key_base(conn), @salt, token, max_age: config.consent_max_age) do
      {:ok, %{params: params, subject: subject}} when is_map(params) and is_binary(subject) ->
        {:ok, %{params: params, subject: subject}}

      _invalid ->
        {:error, {:consent, :expired_consent}}
    end
  end

  defp verify_grant(_conn, _config, _token), do: {:error, {:consent, :missing_consent}}

  # The session may have moved to a different member since the screen rendered.
  defp same_subject(signed, current) do
    if Plug.Crypto.secure_compare(signed, current),
      do: :ok,
      else: {:error, {:consent, :subject_changed}}
  end

  defp current_owner(conn, config) do
    owner = config.resource_owner

    with {:ok, subject} <- owner.current_subject(conn) do
      owner.fetch(subject)
    end
  end

  ## Responses

  defp finish(conn, {:ok, %{redirect_uri: uri, query: query}}), do: redirect(conn, uri, query)
  defp finish(conn, {:error, {:redirect, uri, query}}), do: redirect(conn, uri, query)
  defp finish(conn, {:error, {:invalid_redirect, reason}}), do: invalid_request(conn, reason)

  defp put_default_resource(params, nil), do: params

  defp put_default_resource(params, resource),
    do: Map.put_new(params, "resource", resolve(resource))

  defp redirect(conn, uri, query),
    do: redirect(conn, uri <> "?" <> URI.encode_query(compact(query)))

  defp redirect(conn, url) do
    conn |> put_resp_header("location", url) |> send_resp(302, "") |> halt()
  end

  defp invalid_request(conn, reason) do
    body = %{error: "invalid_request", error_description: to_string(reason)}

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(400, Jason.encode!(body))
    |> halt()
  end

  defp key_base(%{secret_key_base: key} = _conn) when is_binary(key), do: key

  defp key_base(_conn) do
    raise ArgumentError,
          "MCP.OAuth.Plug.Authorize needs conn.secret_key_base to sign the consent grant"
  end

  defp compact(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp resolve({m, f, a}), do: apply(m, f, a)
  defp resolve(value), do: value
end
