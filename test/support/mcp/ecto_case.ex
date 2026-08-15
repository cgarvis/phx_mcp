if Code.ensure_loaded?(Ecto.Adapters.Postgres) do
  defmodule MCP.EctoCase do
    @moduledoc """
    `ExUnit.CaseTemplate` for the `:ecto` suite: starts `MCP.Test.Repo` on
    first use and checks out a Sandbox connection per test.

    Connection config lives in config/config.exs, not here -- see that file
    for why.

    `MCP.Test.Repo.start_link/0` runs from `setup_all`, not `test_helper.exs`,
    so a plain `mix test` never dials Postgres -- `setup_all` only executes
    for a module that has at least one test left after tag filtering, and the
    default suite excludes `:ecto` (see test/test_helper.exs). Multiple
    `:ecto` test modules each call `start_link/0`; matching on
    `{:error, {:already_started, pid}}` makes that safe regardless of which
    one gets there first or whether they run concurrently.
    """

    use ExUnit.CaseTemplate

    using do
      quote do
        import Ecto.Query
        alias MCP.Test.Repo
      end
    end

    setup_all do
      case MCP.Test.Repo.start_link() do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
      end

      Ecto.Adapters.SQL.Sandbox.mode(MCP.Test.Repo, :manual)

      :ok
    end

    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(MCP.Test.Repo)
    end
  end
end
