if Code.ensure_loaded?(Ecto.Schema) do
  defmodule Mix.Tasks.Mcp.Gen.Oauth.Migration do
    @shortdoc "Generates the migration for MCP.OAuth.Store.Ecto's tables"

    @moduledoc """
    Generates the migration that creates `mcp_oauth_clients`,
    `mcp_oauth_codes`, and `mcp_oauth_tokens` -- the three tables
    `MCP.OAuth.Store.Ecto` reads and writes.

        mix mcp.gen.oauth.migration
        mix mcp.gen.oauth.migration -r MyApp.Repo

    Follows `mix ecto.gen.migration` conventions: a timestamped filename,
    written to `priv/repo/migrations` (or wherever the target repo's own
    `:priv` config puts its migrations), and a repo resolved the same way --
    from `--repo`/`-r`, or from `:ecto_repos` in the host app's config when
    that flag is omitted.

    ## Why this is one task and not three calls to `mix ecto.gen.migration`

    The three tables are one unit: `MCP.OAuth.Store.Ecto` does not work with
    only some of them, and hand-writing the column list is exactly the kind
    of transcription a generator exists to avoid -- particularly the two
    columns that are easy to get wrong by copying an existing OAuth schema
    from another app instead of reading `MCP.OAuth.Store.Ecto`'s moduledoc:
    `sub` as `:string`, not `:binary_id`, and the hash columns as `:string`,
    not `:binary`. One generated file, reviewed once, is also one thing to
    read in a PR rather than three.

    ## What it does not do

    It does not grant table privileges to an application role, the way a
    generated migration might in an app with row-level security and a
    dedicated non-superuser connection role. That is a deployment-specific
    concern this library has no way to know about; add a `GRANT` statement to
    the generated file yourself if your setup needs one.

    ## Options

      * `-r`, `--repo` -- the repo to generate the migration for. Repeatable.
        Defaults to every repo listed under `:ecto_repos` for the current
        app.
      * `--migrations-path` -- the directory to write to, bypassing the
        repo's own `:priv` config.
    """

    use Mix.Task

    import Mix.Ecto, only: [parse_repo: 1, ensure_repo: 2]
    import Mix.EctoSQL, only: [source_repo_priv: 1]

    @aliases [r: :repo]
    @switches [repo: [:string, :keep], migrations_path: :string]

    @base_name "create_mcp_oauth_tables.exs"

    @impl Mix.Task
    def run(args) do
      case parse_repo(args) do
        [] ->
          Mix.raise("""
          mix mcp.gen.oauth.migration could not find a repo.

          Pass one explicitly:

              mix mcp.gen.oauth.migration --repo MyApp.Repo

          or configure it in config.exs:

              config :my_app, ecto_repos: [MyApp.Repo]
          """)

        repos ->
          {opts, _positional} = OptionParser.parse!(args, strict: @switches, aliases: @aliases)
          Enum.each(repos, &generate(&1, opts))
      end
    end

    defp generate(repo, opts) do
      ensure_repo(repo, [])
      path = opts[:migrations_path] || Path.join(source_repo_priv(repo), "migrations")
      file = Path.join(path, "#{timestamp()}_#{@base_name}")

      case Path.wildcard(Path.join(path, "*_#{@base_name}")) do
        [] ->
          File.mkdir_p!(path)
          contents = migration_contents(Module.concat([repo, Migrations, CreateMcpOauthTables]))
          create_file(file, contents)
          print_next_steps(repo, file)

        [existing | _rest] ->
          Mix.raise("""
          a migration for the mcp_oauth_* tables already exists:

              #{existing}

          Edit that file, or delete it first if you want a fresh one.
          """)
      end
    end

    defp timestamp do
      {{y, m, d}, {hh, mm, ss}} = :calendar.universal_time()
      "#{y}#{pad(m)}#{pad(d)}#{pad(hh)}#{pad(mm)}#{pad(ss)}"
    end

    defp pad(i) when i < 10, do: "0#{i}"
    defp pad(i), do: to_string(i)

    ## Output

    defp create_file(path, contents) do
      File.write!(path, contents)
      Mix.shell().info([:green, "* creating ", :reset, path])
    end

    defp print_next_steps(repo, file) do
      Mix.shell().info("""

      Review #{file}, then run it:

          mix ecto.migrate -r #{inspect(repo)}

      Point a store at it once the tables exist:

          defmodule MyApp.OAuth.Store do
            use MCP.OAuth.Store.Ecto, repo: #{inspect(repo)}
          end
      """)
    end

    ## Migration contents

    defp migration_contents(mod) do
      """
      defmodule #{inspect(mod)} do
        use Ecto.Migration

        # mcp_oauth_clients, mcp_oauth_codes, mcp_oauth_tokens: fixed table
        # names owned by MCP.OAuth.Store.Ecto, the way oban_jobs is owned by
        # Oban. See that module's moduledoc for the column-by-column
        # reasoning -- in particular, sub is :string (not :binary_id) and
        # every hash column is :string (not :binary).
        def change do
          create table(:mcp_oauth_clients, primary_key: false) do
            add :id, :string, primary_key: true
            add :secret_hash, :string
            add :redirect_uris, {:array, :string}, null: false, default: []
            add :scopes, {:array, :string}, null: false, default: []
            add :grant_types, {:array, :string}, null: false, default: []
            add :confidential, :boolean, null: false, default: false
            add :pkce_required, :boolean, null: false, default: true
            add :name, :string
            add :client_uri, :string
            add :logo_uri, :string
            add :dynamically_registered, :boolean, null: false, default: false
            add :cimd, :boolean, null: false, default: false

            timestamps(type: :utc_datetime)
          end

          # Single-use, hashed at rest. MCP.OAuth.Store.Ecto.take_code/3
          # deletes on read via one atomic DELETE ... RETURNING, so a row
          # never outlives its use -- no separate expiry sweep needed for
          # replay safety, only for cleanup of abandoned (never-redeemed)
          # codes.
          create table(:mcp_oauth_codes) do
            add :code_hash, :string, null: false
            add :client_id, :string, null: false
            add :redirect_uri, :string, null: false
            add :challenge, :string
            add :challenge_method, :string
            add :scope, :string, null: false
            add :sub, :string
            add :resource, :string
            add :expires_at, :utc_datetime, null: false
          end

          create unique_index(:mcp_oauth_codes, [:code_hash])

          # revoked_at (not a boolean) is what MCP.OAuth.Token.revoked?/1 is
          # derived from. Nulls are fine in both unique indexes below:
          # Postgres does not dedupe NULLs, and client_credentials tokens
          # (no refresh_hash) and every not-yet-revoked row are exactly that.
          create table(:mcp_oauth_tokens) do
            add :access_hash, :string, null: false
            add :refresh_hash, :string
            add :client_id, :string, null: false
            add :sub, :string
            add :scope, :string, null: false
            add :audience, {:array, :string}, null: false, default: []
            add :expires_at, :utc_datetime, null: false
            add :revoked_at, :utc_datetime

            timestamps(type: :utc_datetime)
          end

          create unique_index(:mcp_oauth_tokens, [:access_hash])
          create unique_index(:mcp_oauth_tokens, [:refresh_hash])
        end
      end
      """
    end
  end
end
