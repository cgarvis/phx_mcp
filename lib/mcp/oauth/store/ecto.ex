if Code.ensure_loaded?(Ecto.Schema) do
  defmodule MCP.OAuth.Store.Ecto do
    @moduledoc """
    `MCP.OAuth.Store` backed by `Ecto`, on Postgres only.

        defmodule MyApp.OAuth.Store do
          use MCP.OAuth.Store.Ecto, repo: MyApp.Repo
        end

        forward "/mcp", MCP.Plug, auth: {MCP.Auth.OAuth, store: MyApp.OAuth.Store}

    `use MCP.OAuth.Store.Ecto` generates all eight `MCP.OAuth.Store` callbacks
    on `MyApp.OAuth.Store`; there is nothing else to implement. Generate the
    three tables it reads and writes with `mix mcp.gen.oauth.migration`.

    ## Options

      * `:repo` -- an `Ecto.Repo` (required).
      * `:prefix` -- a Postgres schema to run every query against (threaded
        through as the `:prefix` option on every `repo` call). Omit it to use
        the repo's own default.

    ## Why Postgres, not "any Ecto adapter"

    Two things pin this module to Postgres specifically:

      * The array-typed columns (`redirect_uris`, `scopes`, `grant_types`,
        `audience`) are `{:array, :string}`, which the MySQL and SQLite3 Ecto
        adapters do not support.
      * `c:MCP.OAuth.Store.take_code/1` must be atomic delete-on-read (see
        that callback's doc), and this module gets that from a single
        `DELETE ... RETURNING` -- `take_code/3` below -- which is Postgres
        syntax. A transaction-plus-row-lock would work on any adapter, but it
        is a slower, more failure-prone way to say the same thing when the
        database already says it in one statement.

    ## Two columns typed differently than `MCP.OAuth.Client`/`Code`/`Token` might suggest

      * `sub` is `:string`, not `:binary_id`. This library does not assume a
        resource owner's subject is a UUID -- that is a property of *your*
        identity scheme, not this one's. See `MCP.OAuth.Store.Ecto.Token`.
      * The hash columns (`access_hash`, `refresh_hash`, `code_hash`,
        `secret_hash`) are `:string`, not `:binary`. `MCP.OAuth.Secret.hash/1`
        returns lowercase hex, so `:string` is what the value actually is.

    ## Multiple stores

    Each `use` produces an independent module bound to its own `:repo`/
    `:prefix` pair, so two differently-configured stores (a second Postgres
    schema, a second repo entirely) are two modules, not two arguments to one
    module -- the same shape `MCP.OAuth.Store.Memory` gets from process
    naming, but resolved at compile time instead of at the call site.
    """

    defmacro __using__(opts) do
      repo = Keyword.fetch!(opts, :repo)
      prefix = Keyword.get(opts, :prefix)

      quote do
        @behaviour MCP.OAuth.Store

        @impl MCP.OAuth.Store
        def get_client(id),
          do: MCP.OAuth.Store.Ecto.get_client(unquote(repo), unquote(prefix), id)

        @impl MCP.OAuth.Store
        def put_client(client),
          do: MCP.OAuth.Store.Ecto.put_client(unquote(repo), unquote(prefix), client)

        @impl MCP.OAuth.Store
        def put_code(code),
          do: MCP.OAuth.Store.Ecto.put_code(unquote(repo), unquote(prefix), code)

        @impl MCP.OAuth.Store
        def take_code(code_hash),
          do: MCP.OAuth.Store.Ecto.take_code(unquote(repo), unquote(prefix), code_hash)

        @impl MCP.OAuth.Store
        def put_token(token),
          do: MCP.OAuth.Store.Ecto.put_token(unquote(repo), unquote(prefix), token)

        @impl MCP.OAuth.Store
        def get_token(access_hash),
          do: MCP.OAuth.Store.Ecto.get_token(unquote(repo), unquote(prefix), access_hash)

        @impl MCP.OAuth.Store
        def get_refresh(refresh_hash),
          do: MCP.OAuth.Store.Ecto.get_refresh(unquote(repo), unquote(prefix), refresh_hash)

        @impl MCP.OAuth.Store
        def revoke_token(access_hash),
          do: MCP.OAuth.Store.Ecto.revoke_token(unquote(repo), unquote(prefix), access_hash)
      end
    end

    ## Shared implementation -- one copy of the actual queries, called by every
    ## generated store module above rather than duplicated into each of them.
    ## Public (not `defp`) because they are invoked from other modules'
    ## compiled code, but `@doc false`: the seam users implement against is
    ## `MCP.OAuth.Store`'s callbacks, not this arity.

    import Ecto.Query

    alias MCP.OAuth.Store.Ecto.Client, as: ClientSchema
    alias MCP.OAuth.Store.Ecto.Code, as: CodeSchema
    alias MCP.OAuth.Store.Ecto.Token, as: TokenSchema

    @doc false
    @spec get_client(module(), String.t() | nil, String.t()) ::
            {:ok, MCP.OAuth.Client.t()} | :error
    def get_client(repo, prefix, id) do
      case repo.get(ClientSchema, id, repo_opts(prefix)) do
        nil -> :error
        row -> {:ok, to_client(row)}
      end
    end

    @doc false
    @spec put_client(module(), String.t() | nil, MCP.OAuth.Client.t()) :: :ok | {:error, term()}
    def put_client(repo, prefix, %MCP.OAuth.Client{} = client) do
      %ClientSchema{}
      |> ClientSchema.changeset(client_attrs(client))
      |> repo.insert(repo_opts(prefix))
      |> as_result()
    end

    @doc false
    @spec put_code(module(), String.t() | nil, MCP.OAuth.Code.t()) :: :ok | {:error, term()}
    def put_code(repo, prefix, %MCP.OAuth.Code{} = code) do
      %CodeSchema{}
      |> CodeSchema.changeset(code_attrs(code))
      |> repo.insert(repo_opts(prefix))
      |> as_result()
    end

    # The atomicity take_code/1 must have: one DELETE ... RETURNING, not a
    # SELECT followed by a DELETE. Two concurrent callers racing the same
    # code_hash both reach Postgres, but the row lock the DELETE takes
    # serializes them -- one deletes the row and gets it back, the other's
    # DELETE matches zero rows. See test/mcp/oauth/store/ecto_test.exs for the
    # concurrency assertion.
    @doc false
    @spec take_code(module(), String.t() | nil, String.t()) :: {:ok, MCP.OAuth.Code.t()} | :error
    def take_code(repo, prefix, code_hash) do
      query =
        CodeSchema
        |> where([c], c.code_hash == ^code_hash)
        |> select([c], c)

      case repo.delete_all(query, repo_opts(prefix)) do
        {1, [row]} -> {:ok, to_code(row)}
        {0, _rows} -> :error
      end
    end

    @doc false
    @spec put_token(module(), String.t() | nil, MCP.OAuth.Token.t()) :: :ok | {:error, term()}
    def put_token(repo, prefix, %MCP.OAuth.Token{} = token) do
      %TokenSchema{}
      |> TokenSchema.changeset(token_attrs(token))
      |> repo.insert(repo_opts(prefix))
      |> as_result()
    end

    @doc false
    @spec get_token(module(), String.t() | nil, String.t()) :: {:ok, MCP.OAuth.Token.t()} | :error
    def get_token(repo, prefix, access_hash) do
      case repo.get_by(TokenSchema, [access_hash: access_hash], repo_opts(prefix)) do
        nil -> :error
        row -> {:ok, to_token(row)}
      end
    end

    @doc false
    @spec get_refresh(module(), String.t() | nil, String.t()) ::
            {:ok, MCP.OAuth.Token.t()} | :error
    def get_refresh(repo, prefix, refresh_hash) do
      case repo.get_by(TokenSchema, [refresh_hash: refresh_hash], repo_opts(prefix)) do
        nil -> :error
        row -> {:ok, to_token(row)}
      end
    end

    @doc false
    @spec revoke_token(module(), String.t() | nil, String.t()) :: :ok
    def revoke_token(repo, prefix, access_hash) do
      query = where(TokenSchema, [t], t.access_hash == ^access_hash)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      repo.update_all(query, [set: [revoked_at: now]], repo_opts(prefix))

      :ok
    end

    ## Conversions -- MCP.OAuth structs on one side, this module's Ecto
    ## schemas on the other. Every conversion into a schema truncates
    ## DateTime values to second precision, matching the :utc_datetime
    ## columns, and never touches a plaintext secret: MCP.OAuth only ever
    ## hands this module a hash.

    defp repo_opts(nil), do: []
    defp repo_opts(prefix), do: [prefix: prefix]

    defp as_result({:ok, _row}), do: :ok
    defp as_result({:error, changeset}), do: {:error, changeset}

    defp client_attrs(%MCP.OAuth.Client{} = c) do
      %{
        id: c.id,
        secret_hash: c.secret_hash,
        redirect_uris: c.redirect_uris,
        scopes: c.scopes,
        grant_types: c.grant_types,
        confidential: c.confidential?,
        pkce_required: c.pkce_required?,
        name: c.name,
        client_uri: c.client_uri,
        logo_uri: c.logo_uri,
        dynamically_registered: c.dynamically_registered?,
        cimd: c.cimd?
      }
    end

    defp to_client(%ClientSchema{} = row) do
      %MCP.OAuth.Client{
        id: row.id,
        secret_hash: row.secret_hash,
        redirect_uris: row.redirect_uris,
        scopes: row.scopes,
        grant_types: row.grant_types,
        confidential?: row.confidential,
        pkce_required?: row.pkce_required,
        name: row.name,
        client_uri: row.client_uri,
        logo_uri: row.logo_uri,
        dynamically_registered?: row.dynamically_registered,
        cimd?: row.cimd
      }
    end

    defp code_attrs(%MCP.OAuth.Code{} = c) do
      %{
        code_hash: c.code_hash,
        client_id: c.client_id,
        redirect_uri: c.redirect_uri,
        challenge: c.challenge,
        challenge_method: c.challenge_method,
        scope: c.scope,
        sub: c.sub,
        resource: c.resource,
        expires_at: truncate(c.expires_at)
      }
    end

    defp to_code(%CodeSchema{} = row) do
      %MCP.OAuth.Code{
        code_hash: row.code_hash,
        client_id: row.client_id,
        redirect_uri: row.redirect_uri,
        challenge: row.challenge,
        challenge_method: row.challenge_method,
        scope: row.scope,
        sub: row.sub,
        resource: row.resource,
        expires_at: row.expires_at
      }
    end

    defp token_attrs(%MCP.OAuth.Token{} = t) do
      %{
        access_hash: t.access_hash,
        refresh_hash: t.refresh_hash,
        client_id: t.client_id,
        sub: t.sub,
        scope: t.scope,
        audience: t.audience,
        expires_at: truncate(t.expires_at)
      }
    end

    defp to_token(%TokenSchema{} = row) do
      %MCP.OAuth.Token{
        access_hash: row.access_hash,
        refresh_hash: row.refresh_hash,
        client_id: row.client_id,
        sub: row.sub,
        scope: row.scope,
        audience: row.audience,
        expires_at: row.expires_at,
        revoked?: not is_nil(row.revoked_at)
      }
    end

    defp truncate(%DateTime{} = dt), do: DateTime.truncate(dt, :second)
  end
end
