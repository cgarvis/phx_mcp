defmodule MCP.OAuth.Consent do
  @moduledoc """
  Rendering seam for the authorization endpoint's consent screen: the
  library owns the protocol, the host app owns the markup.

  `MCP.OAuth.Plug.Authorize` validates the authorization request, then hands
  `render/2` everything a screen needs to ask the question — who is asking,
  what they would be able to reach, and whether anything vouches for them
  beyond their own registration. The host renders a form that POSTs back to
  `action` with:

    * `grant_token` — the opaque value out of the prompt, verbatim
    * `decision` — `"approve"`, or anything else for a denial

  and whatever CSRF field its own browser pipeline expects; the plug does
  not add CSRF protection of its own.

  The authorization parameters are deliberately *not* read back off that
  POST. `grant_token` is a signed, short-lived copy of the request the
  screen was rendered from, and the plug re-derives the client, redirect_uri
  and scope from it, so a member cannot be shown one scope set and have a
  different one minted — nor can a form field be edited into a wider grant.
  """

  @type prompt :: %{
          client: MCP.OAuth.Client.t(),
          scopes: [String.t()],
          subject: String.t(),
          grant_token: String.t(),
          action: String.t()
        }

  @callback render(Plug.Conn.t(), prompt()) :: Plug.Conn.t()
end
