defmodule MCP.FakePhoenixRouter do
  @moduledoc """
  A minimal stand-in for `Phoenix.Router`'s `scope/2`, `pipe_through/1`, and
  `forward/2,3`, used only to prove that `MCP.Router`'s macros expand into
  calls to those three names, resolved wherever *this* module (not
  `MCP.Router`) is `use`d from.

  `MCP.Router.mcp/2` and `mcp_oauth/2` are written to be Phoenix-free: they
  `quote` code containing unqualified `scope`, `pipe_through`, and `forward`
  calls, which Elixir resolves using the import table of the module the
  generated code lands in, not the module that wrote the `quote` block (see
  `MCP.Router`'s moduledoc). This module is that "lands in" module for the
  test suite, standing in for a real Phoenix router without pulling Phoenix
  in as a test dependency.

  `use`d by a test router, it intercepts `scope(path) do ... end` and reads
  the block's own (unexpanded) AST directly, rather than expanding it, since
  the only shape `MCP.Router` ever generates is a flat `scope` containing one
  `pipe_through/1` followed by one or more `forward/2,3` calls. Each
  `forward` found is recorded as a `{scope_path, pipes, forward_path, plug,
  opts}` tuple; `routes/0` returns them in declaration order.

  `mcp/2` (unlike `mcp_oauth/2`) does not wrap its `forward` in a `scope` of
  its own -- see `MCP.Router`'s moduledoc, it leaves that to the caller, the
  same way a hand-written `forward "/mcp", MCP.Plug, ...` would -- so a bare
  `forward/2,3` is also supported standalone, recorded with `scope_path` and
  `pipes` both `nil`.
  """

  defmacro __using__(_opts) do
    quote do
      Module.register_attribute(__MODULE__, :fake_routes, accumulate: true)
      import MCP.FakePhoenixRouter, only: [scope: 2, forward: 2, forward: 3]
      @before_compile MCP.FakePhoenixRouter
    end
  end

  @doc false
  defmacro forward(path, plug, opts \\ []) do
    quote do
      @fake_routes {nil, nil, unquote(path), unquote(plug), unquote(opts)}
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      @doc false
      def routes, do: Enum.reverse(@fake_routes)
    end
  end

  @doc false
  defmacro scope(path, do: block) do
    exprs =
      case block do
        {:__block__, _meta, exprs} -> exprs
        expr -> [expr]
      end

    pipes = find_pipes(exprs)
    forwards = find_forwards(exprs)

    for {forward_path, plug, forward_opts} <- forwards do
      quote do
        @fake_routes {unquote(path), unquote(pipes), unquote(forward_path), unquote(plug),
                      unquote(forward_opts)}
      end
    end
    |> then(&{:__block__, [], &1})
  end

  defp find_pipes(exprs) do
    Enum.find_value(exprs, fn
      {:pipe_through, _meta, [pipes]} -> pipes
      _other -> nil
    end)
  end

  defp find_forwards(exprs) do
    for {:forward, _meta, args} <- exprs do
      case args do
        [forward_path, plug] -> {forward_path, plug, []}
        [forward_path, plug, forward_opts] -> {forward_path, plug, forward_opts}
      end
    end
  end
end
