defmodule MCP.OAuth do
  @moduledoc """
  Storage-agnostic OAuth 2.0 authorization-server grant handlers.

  Minimal on purpose: the authorization_code (+ PKCE, S256 only),
  refresh_token, and client_credentials grants, plus introspection,
  revocation, and RFC 8707 audience-bound token verification. No OIDC, no
  `id_token`, no userinfo, no jwks — see `MCP.OAuth.Metadata` for the
  advertised capabilities.

  Every function takes a `store` module implementing `MCP.OAuth.Store` as
  its first argument and is otherwise pure — no process state of its own, so
  a host app can call these directly from its own Plug/controller layer.
  Params are string-keyed maps, matching `Plug.Conn` query/body params.

  Secrets never round-trip: `authorize/3` and `token/2` return the one
  plaintext value the caller gets, everything persisted through `store` is
  already a `MCP.OAuth.Secret.hash/1` value.
  """

  alias MCP.OAuth.{Client, Code, PKCE, Secret, Token}

  @code_ttl_seconds 60
  @access_ttl_seconds 3600

  @type params :: %{optional(String.t()) => String.t()}

  ## Authorization endpoint

  @doc """
  Runs the authorization request against an already-authenticated
  `resource_owner` (the host app owns the login/consent UI; this only mints
  the code once it has decided to issue one).

  Returns `{:ok, %{redirect_uri: uri, query: %{code: code, state: state}}}`
  to redirect the user agent back with, or one of two error shapes:

    * `{:error, {:invalid_redirect, reason}}` — the redirect_uri itself
      could not be trusted (unknown client, missing or mismatched
      redirect_uri), so nothing is safe to redirect to. The caller must
      render an error page, not redirect.
    * `{:error, {:redirect, uri, %{error:, error_description:, state:}}}` —
      a recoverable OAuth error (RFC 6749 §4.1.2.1) with a redirect target
      that was validated first.
  """
  @spec authorize(module(), params(), String.t()) ::
          {:ok, %{redirect_uri: String.t(), query: %{code: String.t(), state: term()}}}
          | {:error, {:invalid_redirect, atom()}}
          | {:error, {:redirect, String.t(), map()}}
  def authorize(store, params, resource_owner) do
    with {:ok, client} <- fetch_client_for_redirect(store, params["client_id"]),
         {:ok, redirect_uri} <- match_redirect_uri(client, params["redirect_uri"]),
         :ok <- check_response_type(params["response_type"], redirect_uri, params["state"]),
         :ok <- check_pkce_present(client, params, redirect_uri, params["state"]),
         {:ok, scope} <-
           check_authorize_scope(client, params["scope"], redirect_uri, params["state"]) do
      issue_code(store, client, redirect_uri, scope, params, resource_owner)
    end
  end

  defp fetch_client_for_redirect(store, client_id) when is_binary(client_id) do
    case store.get_client(client_id) do
      {:ok, client} -> {:ok, client}
      :error -> {:error, {:invalid_redirect, :unknown_client}}
    end
  end

  defp fetch_client_for_redirect(_store, _client_id),
    do: {:error, {:invalid_redirect, :missing_client_id}}

  defp match_redirect_uri(%Client{redirect_uris: uris}, redirect_uri)
       when is_binary(redirect_uri) do
    if redirect_uri in uris do
      {:ok, redirect_uri}
    else
      {:error, {:invalid_redirect, :mismatch}}
    end
  end

  defp match_redirect_uri(_client, _redirect_uri),
    do: {:error, {:invalid_redirect, :missing_redirect_uri}}

  defp check_response_type("code", _redirect_uri, _state), do: :ok

  defp check_response_type(_other, redirect_uri, state),
    do:
      {:error,
       redirect_error(
         redirect_uri,
         "unsupported_response_type",
         "only \"code\" is supported",
         state
       )}

  defp check_pkce_present(client, params, redirect_uri, state) do
    challenge = params["code_challenge"]
    method = params["code_challenge_method"]
    required? = client.pkce_required? or not client.confidential?

    cond do
      is_nil(challenge) and required? ->
        {:error,
         redirect_error(redirect_uri, "invalid_request", "code_challenge is required", state)}

      is_nil(challenge) ->
        :ok

      method != "S256" ->
        {:error,
         redirect_error(
           redirect_uri,
           "invalid_request",
           "code_challenge_method must be S256",
           state
         )}

      true ->
        :ok
    end
  end

  defp check_authorize_scope(client, scope, redirect_uri, state) do
    case subset_scope(client.scopes, scope) do
      {:ok, scope} ->
        {:ok, scope}

      :error ->
        {:error,
         redirect_error(
           redirect_uri,
           "invalid_scope",
           "requested scope exceeds client scope",
           state
         )}
    end
  end

  defp issue_code(store, client, redirect_uri, scope, params, resource_owner) do
    plain = Secret.new()

    code = %Code{
      code_hash: Secret.hash(plain),
      client_id: client.id,
      redirect_uri: redirect_uri,
      challenge: params["code_challenge"],
      challenge_method: params["code_challenge_method"],
      scope: scope,
      sub: resource_owner,
      resource: params["resource"],
      expires_at: DateTime.add(DateTime.utc_now(), @code_ttl_seconds, :second)
    }

    case store.put_code(code) do
      :ok ->
        {:ok, %{redirect_uri: redirect_uri, query: %{code: plain, state: params["state"]}}}

      {:error, reason} ->
        {:error, redirect_error(redirect_uri, "server_error", inspect(reason), params["state"])}
    end
  end

  defp redirect_error(redirect_uri, error, description, state),
    do: {:redirect, redirect_uri, %{error: error, error_description: description, state: state}}

  ## Token endpoint

  @doc """
  Runs a token request for the `authorization_code`, `refresh_token`, or
  `client_credentials` grant, dispatched on `params["grant_type"]`.

  Returns `{:ok, %{access_token:, token_type: "bearer", expires_in:,
  refresh_token:, scope:}}` (`refresh_token` is `nil` for client_credentials)
  or `{:error, %{error:, error_description:, status:}}` using RFC 6749 §5.2
  error codes.
  """
  @spec token(module(), params()) :: {:ok, map()} | {:error, map()}
  def token(store, params) do
    case params["grant_type"] do
      "authorization_code" -> authorization_code_grant(store, params)
      "refresh_token" -> refresh_token_grant(store, params)
      "client_credentials" -> client_credentials_grant(store, params)
      _ -> {:error, token_error(400, "unsupported_grant_type", "unsupported grant_type")}
    end
  end

  defp authorization_code_grant(store, params) do
    with {:ok, client} <- authenticate_client(store, params),
         {:ok, code} <- take_valid_code(store, params["code"]),
         :ok <- validate_code_client(code, client),
         :ok <- validate_code_redirect(code, params["redirect_uri"]),
         :ok <- validate_code_pkce(code, params["code_verifier"]) do
      issue_token_pair(store, client.id, code.sub, code.scope, List.wrap(code.resource))
    end
  end

  defp take_valid_code(store, code) when is_binary(code) do
    case store.take_code(Secret.hash(code)) do
      {:ok, %Code{} = code} ->
        reject_if_expired(code, "authorization code expired")

      :error ->
        {:error,
         token_error(400, "invalid_grant", "authorization code is invalid or already used")}
    end
  end

  defp take_valid_code(_store, _code),
    do: {:error, token_error(400, "invalid_request", "code is required")}

  defp reject_if_expired(%{expires_at: expires_at} = record, message) do
    if not_expired?(expires_at) do
      {:ok, record}
    else
      {:error, token_error(400, "invalid_grant", message)}
    end
  end

  defp validate_code_client(%Code{client_id: id}, %Client{id: id}), do: :ok

  defp validate_code_client(_code, _client),
    do: {:error, token_error(400, "invalid_grant", "code was not issued to this client")}

  defp validate_code_redirect(%Code{redirect_uri: uri}, uri), do: :ok

  defp validate_code_redirect(_code, _redirect_uri),
    do:
      {:error,
       token_error(400, "invalid_grant", "redirect_uri does not match the authorization request")}

  defp validate_code_pkce(%Code{challenge: nil}, _verifier), do: :ok

  defp validate_code_pkce(%Code{challenge: challenge, challenge_method: method}, verifier)
       when is_binary(verifier) do
    if PKCE.verify(verifier, challenge, method) do
      :ok
    else
      {:error, token_error(400, "invalid_grant", "PKCE verification failed")}
    end
  end

  defp validate_code_pkce(%Code{}, _verifier),
    do: {:error, token_error(400, "invalid_request", "code_verifier is required")}

  defp refresh_token_grant(store, params) do
    with {:ok, client} <- authenticate_client(store, params),
         {:ok, old_token} <- fetch_valid_refresh(store, params["refresh_token"]),
         :ok <- validate_token_client(old_token, client),
         {:ok, scope} <-
           require_scope(String.split(old_token.scope, " ", trim: true), params["scope"]),
         {:ok, audience} <- audience_from_request(old_token.audience, params["resource"]) do
      :ok = store.revoke_token(old_token.access_hash)
      issue_token_pair(store, client.id, old_token.sub, scope, audience)
    end
  end

  defp fetch_valid_refresh(store, refresh_token) when is_binary(refresh_token) do
    case store.get_refresh(Secret.hash(refresh_token)) do
      {:ok, %Token{revoked?: true}} ->
        {:error, token_error(400, "invalid_grant", "refresh token has been revoked")}

      {:ok, %Token{} = token} ->
        {:ok, token}

      :error ->
        {:error, token_error(400, "invalid_grant", "refresh token is invalid")}
    end
  end

  defp fetch_valid_refresh(_store, _refresh_token),
    do: {:error, token_error(400, "invalid_request", "refresh_token is required")}

  defp validate_token_client(%Token{client_id: id}, %Client{id: id}), do: :ok

  defp validate_token_client(_token, _client),
    do: {:error, token_error(400, "invalid_grant", "refresh token was not issued to this client")}

  defp audience_from_request(audience, nil), do: {:ok, audience}
  defp audience_from_request(audience, ""), do: {:ok, audience}

  defp audience_from_request(audience, resource) when is_binary(resource) do
    if resource in audience do
      {:ok, [resource]}
    else
      {:error, token_error(400, "invalid_target", "resource exceeds the original grant")}
    end
  end

  defp client_credentials_grant(store, params) do
    with {:ok, client} <- authenticate_confidential_client(store, params),
         {:ok, scope} <- require_scope(client.scopes, params["scope"]) do
      audience = List.wrap(params["resource"])
      issue_token(store, client.id, nil, scope, audience, refresh?: false)
    end
  end

  ## Client authentication

  defp authenticate_client(store, params) do
    with {:ok, client_id} <- require_param(params, "client_id"),
         {:ok, client} <- fetch_client_for_token(store, client_id),
         :ok <- verify_optional_secret(client, params["client_secret"]) do
      {:ok, client}
    end
  end

  defp authenticate_confidential_client(store, params) do
    with {:ok, client_id} <- require_param(params, "client_id"),
         {:ok, client} <- fetch_client_for_token(store, client_id),
         :ok <- require_confidential(client),
         {:ok, secret} <- require_param(params, "client_secret"),
         :ok <- verify_secret(client, secret) do
      {:ok, client}
    end
  end

  defp require_param(params, key) do
    case params[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, token_error(400, "invalid_request", "#{key} is required")}
    end
  end

  defp fetch_client_for_token(store, client_id) do
    case store.get_client(client_id) do
      {:ok, client} -> {:ok, client}
      :error -> {:error, token_error(401, "invalid_client", "unknown client")}
    end
  end

  defp require_confidential(%Client{confidential?: true}), do: :ok

  defp require_confidential(%Client{}),
    do:
      {:error,
       token_error(
         400,
         "unauthorized_client",
         "client_credentials requires a confidential client"
       )}

  defp verify_optional_secret(%Client{secret_hash: nil}, _secret), do: :ok

  defp verify_optional_secret(%Client{} = client, secret) when is_binary(secret),
    do: verify_secret(client, secret)

  defp verify_optional_secret(%Client{}, _secret),
    do: {:error, token_error(401, "invalid_client", "client authentication failed")}

  defp verify_secret(%Client{secret_hash: hash}, secret) when is_binary(hash) do
    if Plug.Crypto.secure_compare(Secret.hash(secret), hash) do
      :ok
    else
      {:error, token_error(401, "invalid_client", "client authentication failed")}
    end
  end

  defp verify_secret(%Client{}, _secret),
    do: {:error, token_error(401, "invalid_client", "client authentication failed")}

  ## Scope

  defp subset_scope(allowed, nil), do: {:ok, Enum.join(allowed, " ")}
  defp subset_scope(allowed, ""), do: {:ok, Enum.join(allowed, " ")}

  defp subset_scope(allowed, requested) when is_binary(requested) do
    wanted = String.split(requested, " ", trim: true)

    if Enum.all?(wanted, &(&1 in allowed)) do
      {:ok, Enum.join(wanted, " ")}
    else
      :error
    end
  end

  defp require_scope(allowed, requested) do
    case subset_scope(allowed, requested) do
      {:ok, scope} ->
        {:ok, scope}

      :error ->
        {:error, token_error(400, "invalid_scope", "requested scope exceeds client scope")}
    end
  end

  ## Token issuance

  defp issue_token_pair(store, client_id, sub, scope, audience),
    do: issue_token(store, client_id, sub, scope, audience, refresh?: true)

  defp issue_token(store, client_id, sub, scope, audience, refresh?: refresh?) do
    access_plain = Secret.new()
    refresh_plain = if refresh?, do: Secret.new()

    token = %Token{
      access_hash: Secret.hash(access_plain),
      refresh_hash: refresh_plain && Secret.hash(refresh_plain),
      client_id: client_id,
      sub: sub,
      scope: scope,
      audience: audience,
      expires_at: DateTime.add(DateTime.utc_now(), @access_ttl_seconds, :second)
    }

    case store.put_token(token) do
      :ok ->
        {:ok,
         %{
           access_token: access_plain,
           token_type: "bearer",
           expires_in: @access_ttl_seconds,
           refresh_token: refresh_plain,
           scope: token.scope
         }}

      {:error, reason} ->
        {:error, token_error(500, "server_error", inspect(reason))}
    end
  end

  defp token_error(status, error, description),
    do: %{error: error, error_description: description, status: status}

  ## Introspection and revocation (RFC 7662, RFC 7009)

  @doc "RFC 7662 introspection: an active-token map, or `%{active: false}` for anything else."
  @spec introspect(module(), params()) :: map()
  def introspect(store, %{"token" => token}) when is_binary(token) do
    case lookup_active(store, Secret.hash(token)) do
      {:ok, t} ->
        %{
          active: true,
          scope: t.scope,
          client_id: t.client_id,
          sub: t.sub,
          aud: t.audience,
          exp: DateTime.to_unix(t.expires_at)
        }

      :error ->
        %{active: false}
    end
  end

  def introspect(_store, _params), do: %{active: false}

  @doc "RFC 7009 revocation. Idempotent: revoking an unknown or already-revoked token still returns `:ok`."
  @spec revoke(module(), params()) :: :ok
  def revoke(store, %{"token" => token}) when is_binary(token),
    do: store.revoke_token(Secret.hash(token))

  def revoke(_store, _params), do: :ok

  ## Resource-server verification

  @doc """
  Verifies a bearer token presented to a resource server.

  When `resource` is non-nil the token's audience (RFC 8707) must contain
  it — a token minted for one MCP server must not authenticate to another.
  """
  @spec verify_token(module(), String.t(), String.t() | nil) ::
          {:ok,
           %{
             principal: String.t(),
             scopes: [String.t()],
             sub: String.t() | nil,
             client_id: String.t()
           }}
          | {:error, :invalid_token}
  def verify_token(store, token, resource) when is_binary(token) do
    with {:ok, t} <- lookup_active(store, Secret.hash(token)),
         :ok <- check_audience(t.audience, resource) do
      {:ok,
       %{
         principal: t.sub || "client:" <> t.client_id,
         scopes: String.split(t.scope, " ", trim: true),
         sub: t.sub,
         client_id: t.client_id
       }}
    else
      _ -> {:error, :invalid_token}
    end
  end

  def verify_token(_store, _token, _resource), do: {:error, :invalid_token}

  defp lookup_active(store, hash) do
    case store.get_token(hash) do
      {:ok, %Token{revoked?: true}} ->
        :error

      {:ok, %Token{expires_at: expires_at} = t} ->
        if(not_expired?(expires_at), do: {:ok, t}, else: :error)

      :error ->
        :error
    end
  end

  defp not_expired?(expires_at), do: DateTime.compare(DateTime.utc_now(), expires_at) == :lt

  defp check_audience(_audience, nil), do: :ok

  defp check_audience(audience, resource),
    do: if(resource in audience, do: :ok, else: {:error, :invalid_token})
end
