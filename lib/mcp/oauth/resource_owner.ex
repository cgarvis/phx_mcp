defmodule MCP.OAuth.ResourceOwner do
  @moduledoc """
  Identity seam for `MCP.OAuth.Plug.Authorize`: who is signed in behind this
  request, and are they still allowed to authorize a client.

  The authorization endpoint is the one OAuth endpoint tied to an application
  login, and every app authenticates differently (a session cookie here, a
  header elsewhere), so the plug defers both questions to the host:

    * `current_subject/1` reads the request's own login and returns the subject
      id to embed in the code, or `:error` when no one is signed in.
    * `fetch/1` re-reads that subject from the source of truth, so a still-valid
      session for a since-suspended account cannot mint an authorization code.

  They are separate callbacks because a valid login and a still-authorized
  account are different facts; the plug requires both.
  """

  @callback current_subject(Plug.Conn.t()) :: {:ok, String.t()} | :error
  @callback fetch(subject :: String.t()) :: {:ok, String.t()} | :error
end
