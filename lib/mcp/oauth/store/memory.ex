defmodule MCP.OAuth.Store.Memory do
  @moduledoc """
  In-memory `MCP.OAuth.Store`, backed by an `Agent` — for tests, not production.

  The behaviour callbacks are fixed-arity (no store handle to thread
  through), so instances are addressed by process name; pass `name:` to
  `start_link/1` and to `put_client/2` etc. to run more than one in a test
  suite, or rely on the `__MODULE__` default for a single global instance.

  `take_code/1` gets its atomicity from the Agent's single mailbox: a
  `get_and_update` runs as one message, so two concurrent callers can never
  both pop the same code.
  """

  @behaviour MCP.OAuth.Store

  use Agent

  alias MCP.OAuth.{Client, Code, Token}

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Agent.start_link(fn -> %{clients: %{}, codes: %{}, tokens: %{}, refresh: %{}} end, name: name)
  end

  @doc "Registers a client for the given instance — test/dev seeding, not a Store callback."
  @spec put_client(GenServer.name(), Client.t()) :: :ok
  def put_client(name \\ __MODULE__, %Client{} = client) do
    Agent.update(name, &put_in(&1, [:clients, client.id], client))
  end

  @impl MCP.OAuth.Store
  def get_client(id), do: get_client(__MODULE__, id)

  @spec get_client(GenServer.name(), String.t()) :: {:ok, Client.t()} | :error
  def get_client(name, id) do
    case Agent.get(name, &get_in(&1, [:clients, id])) do
      nil -> :error
      client -> {:ok, client}
    end
  end

  @impl MCP.OAuth.Store
  def put_code(%Code{} = code), do: put_code(__MODULE__, code)

  @spec put_code(GenServer.name(), Code.t()) :: :ok
  def put_code(name, %Code{} = code) do
    Agent.update(name, &put_in(&1, [:codes, code.code_hash], code))
  end

  @impl MCP.OAuth.Store
  def take_code(code_hash), do: take_code(__MODULE__, code_hash)

  @spec take_code(GenServer.name(), String.t()) :: {:ok, Code.t()} | :error
  def take_code(name, code_hash) do
    Agent.get_and_update(name, fn state ->
      case Map.pop(state.codes, code_hash) do
        {nil, _codes} -> {:error, state}
        {code, codes} -> {{:ok, code}, %{state | codes: codes}}
      end
    end)
  end

  @impl MCP.OAuth.Store
  def put_token(%Token{} = token), do: put_token(__MODULE__, token)

  @spec put_token(GenServer.name(), Token.t()) :: :ok
  def put_token(name, %Token{} = token) do
    Agent.update(name, fn state ->
      state = put_in(state, [:tokens, token.access_hash], token)

      if token.refresh_hash do
        put_in(state, [:refresh, token.refresh_hash], token.access_hash)
      else
        state
      end
    end)
  end

  @impl MCP.OAuth.Store
  def get_token(access_hash), do: get_token(__MODULE__, access_hash)

  @spec get_token(GenServer.name(), String.t()) :: {:ok, Token.t()} | :error
  def get_token(name, access_hash) do
    case Agent.get(name, &get_in(&1, [:tokens, access_hash])) do
      nil -> :error
      token -> {:ok, token}
    end
  end

  @impl MCP.OAuth.Store
  def get_refresh(refresh_hash), do: get_refresh(__MODULE__, refresh_hash)

  @spec get_refresh(GenServer.name(), String.t()) :: {:ok, Token.t()} | :error
  def get_refresh(name, refresh_hash) do
    Agent.get(name, fn state ->
      with access_hash when is_binary(access_hash) <- Map.get(state.refresh, refresh_hash),
           token when not is_nil(token) <- get_in(state, [:tokens, access_hash]) do
        {:ok, token}
      else
        _ -> :error
      end
    end)
  end

  @impl MCP.OAuth.Store
  def revoke_token(access_hash), do: revoke_token(__MODULE__, access_hash)

  @spec revoke_token(GenServer.name(), String.t()) :: :ok
  def revoke_token(name, access_hash) do
    Agent.update(name, fn state ->
      case Map.get(state.tokens, access_hash) do
        nil -> state
        token -> put_in(state, [:tokens, access_hash], %{token | revoked?: true})
      end
    end)
  end
end
