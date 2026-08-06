defmodule MCP.OAuth.Store do
  @moduledoc """
  Persistence seam `MCP.OAuth` calls into; the host app implements it.

  Every argument and lookup key crossing this boundary is a hash, never a
  plaintext secret — see `MCP.OAuth.Secret`.

  `take_code/1` MUST be atomic delete-on-read: fetch and remove the code in
  one indivisible operation (a DB transaction with a row lock and a delete,
  or a single-process serializer like an `Agent`/`GenServer` handling both
  steps under one message). Two concurrent `take_code/1` calls for the same
  hash must not both return `{:ok, code}` — exactly one may, the other gets
  `:error`. Anything weaker turns a single-use authorization code into a
  replayable one.
  """

  alias MCP.OAuth.{Client, Code, Token}

  @callback get_client(id :: String.t()) :: {:ok, Client.t()} | :error
  @callback put_code(Code.t()) :: :ok | {:error, term()}
  @callback take_code(code_hash :: String.t()) :: {:ok, Code.t()} | :error
  @callback put_token(Token.t()) :: :ok | {:error, term()}
  @callback get_token(access_hash :: String.t()) :: {:ok, Token.t()} | :error
  @callback get_refresh(refresh_hash :: String.t()) :: {:ok, Token.t()} | :error
  @callback revoke_token(access_hash :: String.t()) :: :ok
end
