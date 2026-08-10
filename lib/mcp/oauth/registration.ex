defmodule MCP.OAuth.Registration do
  @moduledoc """
  RFC 7591 dynamic client registration: client metadata in, a
  `MCP.OAuth.Client` out, with no store and no I/O.

  Registration here is open — no initial access token, because MCP clients
  do not send one — so the shape it produces is the least-privileged one the
  library has. Whatever the request asked for, a self-registered client is
  public (no secret, `token_endpoint_auth_method: "none"`), PKCE-enforced,
  and limited to `authorization_code` + `refresh_token`.

  `client_credentials` is refused rather than dropped. That grant has no
  resource owner (see `MCP.OAuth.token/2`), so a self-registered machine
  client would mint a token against member data with nobody consenting;
  silently downgrading the request would leave the caller believing it had
  a machine credential. Machine clients stay an operator action.

  Requested scopes are intersected with the host's declared set. Absent
  scope, the client is registered for the full declared set: registration
  decides the ceiling, the consent screen decides what a member actually
  hands over.

  Every rejection is one of RFC 7591 §3.2.2's two error codes —
  `invalid_redirect_uri` or `invalid_client_metadata` — returned as
  `{:error, {code, description}}` for the caller to render.
  """

  alias MCP.OAuth.{Client, Secret}

  @grant_types ["authorization_code", "refresh_token"]
  @response_types ["code"]

  # Bounds on an unauthenticated write. Generous against real clients
  # (Claude registers one https callback), tight against a row stuffer.
  # 255 is also the widest a `varchar(255)` store column takes, so an
  # over-long URI is a 400 here rather than a 500 on insert.
  @max_redirect_uris 10
  @max_uri_length 255
  @max_name_length 128

  @loopback_hosts ["127.0.0.1", "::1", "localhost"]

  @default_name "Unnamed client"

  @type error :: {String.t(), String.t()}

  @doc """
  Builds a registrable client from an RFC 7591 metadata map.

  Options:

    * `:scopes` — the scopes this AS can issue; the requested scope is
      intersected with it (default `[]`)
    * `:client_id` — a fixed id instead of a generated one, for tests
  """
  @spec build(map(), keyword()) :: {:ok, Client.t()} | {:error, error()}
  def build(metadata, opts \\ [])

  def build(metadata, opts) when is_map(metadata) do
    allowed = Keyword.get(opts, :scopes, [])

    with {:ok, redirect_uris} <- redirect_uris(metadata["redirect_uris"]),
         {:ok, name} <- client_name(metadata["client_name"]),
         :ok <- check_grant_types(metadata["grant_types"]),
         :ok <- check_response_types(metadata["response_types"]),
         {:ok, scopes} <- scopes(metadata["scope"], allowed),
         {:ok, client_uri} <- display_uri(metadata["client_uri"], "client_uri"),
         {:ok, logo_uri} <- display_uri(metadata["logo_uri"], "logo_uri") do
      {:ok,
       %Client{
         id: Keyword.get_lazy(opts, :client_id, &generate_id/0),
         secret_hash: nil,
         redirect_uris: redirect_uris,
         scopes: scopes,
         grant_types: @grant_types,
         confidential?: false,
         pkce_required?: true,
         name: name,
         client_uri: client_uri,
         logo_uri: logo_uri,
         dynamically_registered?: true
       }}
    end
  end

  def build(_metadata, _opts),
    do: {:error, invalid_metadata("the request body must be a JSON object")}

  @doc """
  The RFC 7591 §3.2.1 registration response for `client`.

  Carries no `client_secret`: every client this module builds is public.
  Values the request asked for but did not get (`grant_types`,
  `token_endpoint_auth_method`, `scope`) are echoed back as registered, which
  is how the client learns it was narrowed.
  """
  @spec response(Client.t(), integer()) :: map()
  def response(%Client{} = client, issued_at) do
    %{
      "client_id" => client.id,
      "client_id_issued_at" => issued_at,
      "client_name" => client.name,
      "redirect_uris" => client.redirect_uris,
      "grant_types" => client.grant_types,
      "response_types" => @response_types,
      "token_endpoint_auth_method" => "none",
      "scope" => Enum.join(client.scopes, " ")
    }
  end

  ## redirect_uris

  defp redirect_uris(uris) when is_list(uris) and uris != [] do
    cond do
      length(uris) > @max_redirect_uris ->
        {:error, invalid_redirect("at most #{@max_redirect_uris} redirect_uris")}

      not Enum.all?(uris, &is_binary/1) ->
        {:error, invalid_redirect("every redirect_uri must be a string")}

      true ->
        Enum.reduce_while(uris, {:ok, uris}, fn uri, acc ->
          case check_redirect_uri(uri) do
            :ok -> {:cont, acc}
            {:error, _reason} = error -> {:halt, error}
          end
        end)
    end
  end

  defp redirect_uris([]), do: {:error, invalid_redirect("redirect_uris must not be empty")}

  defp redirect_uris(_uris),
    do: {:error, invalid_redirect("redirect_uris is required and must be an array")}

  # Stored and matched verbatim (MCP.OAuth matches by exact string), so every
  # rejection here is a rejection of the literal the client will send back.
  defp check_redirect_uri(uri) do
    cond do
      byte_size(uri) > @max_uri_length ->
        {:error, invalid_redirect("redirect_uri is longer than #{@max_uri_length} bytes")}

      String.contains?(uri, "*") ->
        {:error, invalid_redirect("redirect_uri must not contain a wildcard: #{uri}")}

      true ->
        check_redirect_parts(uri, URI.parse(uri))
    end
  end

  defp check_redirect_parts(uri, %URI{fragment: fragment}) when not is_nil(fragment),
    do: {:error, invalid_redirect("redirect_uri must not carry a fragment: #{uri}")}

  defp check_redirect_parts(uri, %URI{userinfo: userinfo}) when not is_nil(userinfo),
    do: {:error, invalid_redirect("redirect_uri must not carry userinfo: #{uri}")}

  defp check_redirect_parts(uri, %URI{scheme: "https", host: host}) do
    if is_binary(host) and host != "" do
      :ok
    else
      {:error, invalid_redirect("redirect_uri must name a host: #{uri}")}
    end
  end

  defp check_redirect_parts(uri, %URI{scheme: "http", host: host}) do
    if host in @loopback_hosts do
      :ok
    else
      {:error, invalid_redirect("http is only allowed on 127.0.0.1, ::1, or localhost: #{uri}")}
    end
  end

  defp check_redirect_parts(uri, %URI{}),
    do: {:error, invalid_redirect("redirect_uri must be https, or http on loopback: #{uri}")}

  ## The rest of the metadata

  defp client_name(nil), do: {:ok, @default_name}

  defp client_name(name) when is_binary(name) do
    case String.trim(name) do
      "" -> {:ok, @default_name}
      trimmed when byte_size(trimmed) > @max_name_length -> {:error, name_too_long()}
      trimmed -> {:ok, trimmed}
    end
  end

  defp client_name(_name), do: {:error, invalid_metadata("client_name must be a string")}

  defp name_too_long,
    do: invalid_metadata("client_name is longer than #{@max_name_length} bytes")

  defp check_grant_types(nil), do: :ok

  defp check_grant_types(types) when is_list(types) do
    cond do
      "client_credentials" in types ->
        {:error,
         invalid_metadata(
           "client_credentials cannot be registered dynamically: it has no resource owner"
         )}

      Enum.all?(types, &(&1 in @grant_types)) ->
        :ok

      true ->
        {:error,
         invalid_metadata("grant_types must be a subset of #{Enum.join(@grant_types, ", ")}")}
    end
  end

  defp check_grant_types(_types), do: {:error, invalid_metadata("grant_types must be an array")}

  defp check_response_types(nil), do: :ok

  defp check_response_types(types) when is_list(types) do
    if Enum.all?(types, &(&1 in @response_types)) do
      :ok
    else
      {:error, invalid_metadata("only the \"code\" response_type is supported")}
    end
  end

  defp check_response_types(_types),
    do: {:error, invalid_metadata("response_types must be an array")}

  defp scopes(nil, allowed), do: {:ok, allowed}
  defp scopes("", allowed), do: {:ok, allowed}

  defp scopes(scope, allowed) when is_binary(scope) do
    case scope |> String.split(" ", trim: true) |> Enum.filter(&(&1 in allowed)) do
      [] -> {:error, invalid_metadata("none of the requested scopes are supported")}
      granted -> {:ok, granted}
    end
  end

  defp scopes(_scope, _allowed),
    do: {:error, invalid_metadata("scope must be a space-delimited string")}

  # Display-only, and never fetched: an https URL the consent screen shows as text.
  defp display_uri(nil, _field), do: {:ok, nil}
  defp display_uri("", _field), do: {:ok, nil}

  defp display_uri(uri, field) when is_binary(uri) do
    cond do
      byte_size(uri) > @max_uri_length ->
        {:error, invalid_metadata("#{field} is longer than #{@max_uri_length} bytes")}

      match?(
        %URI{scheme: "https", host: host} when is_binary(host) and host != "",
        URI.parse(uri)
      ) ->
        {:ok, uri}

      true ->
        {:error, invalid_metadata("#{field} must be an https URL")}
    end
  end

  defp display_uri(_uri, field), do: {:error, invalid_metadata("#{field} must be a string")}

  defp generate_id, do: "client_" <> Secret.new()

  defp invalid_redirect(description), do: {"invalid_redirect_uri", description}
  defp invalid_metadata(description), do: {"invalid_client_metadata", description}
end
