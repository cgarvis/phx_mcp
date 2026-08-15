defmodule Mix.Tasks.Mcp.Gen.Oauth.MigrationTest do
  # Not async: writes real files and shells out to Mix.Task.run("app.config").
  # No database involved -- ensure_repo/2 only loads config and checks the
  # module is compiled, it never starts a connection -- so this stays
  # untagged and runs in the default suite.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @moduledoc false

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "mcp_gen_oauth_migration_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp run(args) do
    capture_io(fn -> Mix.Tasks.Mcp.Gen.Oauth.Migration.run(args) end)
  end

  defp only_file(dir) do
    [path] = Path.wildcard(Path.join(dir, "*.exs"))
    path
  end

  test "writes a timestamped migration creating all three tables", %{dir: dir} do
    run(["--repo", "MCP.Test.Repo", "--migrations-path", dir])

    path = only_file(dir)
    assert Path.basename(path) =~ ~r/^\d{14}_create_mcp_oauth_tables\.exs$/

    contents = File.read!(path)
    assert contents =~ "defmodule MCP.Test.Repo.Migrations.CreateMcpOauthTables do"
    assert contents =~ "create table(:mcp_oauth_clients"
    assert contents =~ "create table(:mcp_oauth_codes"
    assert contents =~ "create table(:mcp_oauth_tokens"
    assert contents =~ "unique_index(:mcp_oauth_codes, [:code_hash])"
    assert contents =~ "unique_index(:mcp_oauth_tokens, [:access_hash])"
    assert contents =~ "unique_index(:mcp_oauth_tokens, [:refresh_hash])"

    # The point of the generator is that what it writes compiles as a real
    # Ecto.Migration, so the assertion goes through the compiler.
    assert [{module, _bytecode}] = Code.compile_string(contents)
    assert module == MCP.Test.Repo.Migrations.CreateMcpOauthTables
    assert function_exported?(module, :change, 0)
  end

  test "the divergent columns from a naive Moxie-style port are present", %{dir: dir} do
    run(["--repo", "MCP.Test.Repo", "--migrations-path", dir])
    contents = dir |> only_file() |> File.read!()

    # sub and every hash column are :string, not :binary_id / :binary.
    assert contents =~ "add :sub, :string"
    assert contents =~ "add :code_hash, :string"
    assert contents =~ "add :access_hash, :string"
    assert contents =~ "add :pkce_required, :boolean, null: false, default: true"
    assert contents =~ "add :dynamically_registered, :boolean, null: false, default: false"
    assert contents =~ "add :cimd, :boolean, null: false, default: false"
  end

  test "running it twice against the same path raises instead of overwriting", %{dir: dir} do
    run(["--repo", "MCP.Test.Repo", "--migrations-path", dir])

    assert_raise Mix.Error, ~r/already exists/, fn ->
      run(["--repo", "MCP.Test.Repo", "--migrations-path", dir])
    end

    assert length(Path.wildcard(Path.join(dir, "*.exs"))) == 1
  end

  test "raises a helpful error when no repo can be found" do
    # config/config.exs sets :ecto_repos for MCP.Test.Repo, since this
    # library's own test suite needs it -- clear it so this test exercises
    # what a host project sees before it configures a repo at all.
    ecto_repos = Application.get_env(:phx_mcp, :ecto_repos)
    Application.delete_env(:phx_mcp, :ecto_repos)

    try do
      assert_raise Mix.Error, ~r/could not find a repo/, fn ->
        run([])
      end
    after
      Application.put_env(:phx_mcp, :ecto_repos, ecto_repos)
    end
  end
end
