defmodule MCP.OAuth.CIMD.Cache do
  @moduledoc """
  TTL cache for fetched CIMD documents, over an ETS table this process owns.

  Node-local, not replicated: a miss just re-fetches over HTTPS (cheap,
  idempotent, still SSRF-guarded), so there is nothing to gain from
  cross-node replication and no correctness requirement to invalidate
  cluster-wide. Holds no member or tenant data.

  Optional. `get/2` and `put/4` treat a missing table as a permanent miss, so
  a host that never starts this process still resolves — it just fetches
  every time. Start it under a supervisor to stop that:

      children = [MCP.OAuth.CIMD.Cache]

  Entries expire lazily on read; a periodic sweep drops the ones nobody
  reads again, so an attacker walking distinct client_id URLs cannot grow the
  table without bound.
  """

  use GenServer

  @table __MODULE__
  @sweep_interval_ms 60_000

  @doc "Starts the cache. `:name` and `:table` exist so tests can run isolated copies."
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "The cached value for `key`, or nil on a miss or an expired entry."
  @spec get(term(), keyword()) :: term() | nil
  def get(key, opts \\ []) do
    table = Keyword.get(opts, :table, @table)

    case :ets.lookup(table, key) do
      [{^key, value, expires_at}] ->
        if monotonic_ms() < expires_at, do: value, else: nil

      [] ->
        nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "Caches `value` under `key` for `ttl_ms`."
  @spec put(term(), term(), non_neg_integer(), keyword()) :: :ok
  def put(key, value, ttl_ms, opts \\ []) do
    table = Keyword.get(opts, :table, @table)
    :ets.insert(table, {key, value, monotonic_ms() + ttl_ms})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl GenServer
  def init(opts) do
    table = Keyword.get(opts, :table, @table)
    :ets.new(table, [:named_table, :set, :public, read_concurrency: true])
    schedule_sweep()
    {:ok, %{table: table}}
  end

  @impl GenServer
  def handle_info(:sweep, %{table: table} = state) do
    :ets.select_delete(table, [{{:_, :_, :"$1"}, [{:<, :"$1", monotonic_ms()}], [true]}])
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
