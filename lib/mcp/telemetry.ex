defmodule MCP.Telemetry do
  @moduledoc """
  Telemetry events emitted by the MCP kernel.

  Attach with `:telemetry.attach_many/4`; the kernel never installs handlers of
  its own, so a host app decides what to do with these.

  ## What these spans deliberately never carry

  No tool arguments, no tool results, no resource bodies, no prompt arguments,
  no request or response payloads. Not as a default to be widened later: the
  kernel has no way to know that a tool's arguments are a search string rather
  than a bearer token, or that a resource body is a README rather than a row of
  customer records, and a span is copied to wherever the host ships telemetry.
  A name, a method, and a duration describe a call; the call's contents
  describe the data it touched, and those are different things. The `:reason`
  and `:stacktrace` on exception metadata are the exception term itself, which
  a host already has to treat as sensitive.

  ## `[:mcp, :request, :start | :stop | :exception]`

  One span per authenticated JSON-RPC request, emitted by `MCP.Plug`.

    * start measurements — `:system_time`
    * stop/exception measurements — `:duration` (native units)
    * metadata — `:method` (the JSON-RPC method), `:name` (tool name, resource
      URI, or prompt name when the request carries one, else `nil`),
      `:principal`, `:granted_scopes`, `:client`, `:protocol_version`,
      `:session_id`,
      `:user_agent`, `:vendor_client`, and on stop `:status` (HTTP status) plus
      `:error_code` (the JSON-RPC error code, `nil` on success)
    * exception metadata — `:kind`, `:reason`, `:stacktrace`

  A raise that escapes the handler layer becomes a 500 at the transport, so it
  gets `:exception` and no `:stop`; a span that only ever stopped would leave
  those requests invisible to latency and error dashboards alike.

  Requests rejected before a method is known (disallowed origin, bad token,
  unparseable body) emit no span: there is nothing to attribute them to.

  ### Caller metadata

    * `:granted_scopes` — `[String.t()]`, the scopes the caller holds, from
      `MCP.Context`. Every list and every lookup in the request is filtered by
      these, so two callers issuing the identical request can legitimately see
      different results; without them on the span that divergence looks like
      nondeterminism.

      The name is qualified, rather than a bare `:scopes`, because the handler
      span carries a scope list too and it means the opposite thing — see
      `:required_scopes` below.

    * `:client` — `map() | nil`, the client's `_meta` `clientInfo` object
      verbatim (`%{"name" => ..., "version" => ...}` by convention, but the
      spec does not constrain it and nothing verifies it). Passed through
      rather than flattened into a name and a version, because a client that
      sends keys we did not anticipate should reach the host intact instead of
      being silently reduced. `nil` when the client sent none — the spec makes
      `clientInfo` optional — and also when it sent something that is not an
      object at all, since the alternative is handing a consumer a bare string
      under a key every type signature here promises is a map. Its *size* is
      not bounded: the value is whatever fits in the request body, and it is
      copied onto every span, so a host shipping spans off-node should be aware
      it is forwarding caller-controlled content of caller-chosen size.

    * `:protocol_version` — `String.t() | nil`, the revision the request
      declared in `_meta`, read *before* negotiation runs. A request declaring
      a version this server refuses is exactly the request worth counting, and
      it still produces a span; reading the negotiated value instead would
      report `nil` for every one of them, which is the opposite of useful.
      Through `MCP.Plug` this is always a string — the pre-2026-07-28
      compatibility shim stamps this server's own revision onto a request that
      declares none, so the span reports the revision dispatch actually ran
      under. `nil` is reachable only for an `MCP.Context` a host builds itself
      and hands to `MCP.Server.dispatch/4`.

    * `:user_agent` — `String.t() | nil`, the raw `User-Agent` request header.
      HTTP only, and self-reported. It is the only field that distinguishes
      build variants of one client — a CLI and an SDK shipping under the same
      `clientInfo` name — so it is passed through raw rather than parsed into
      product and version, which would discard the comment field where that
      distinction actually lives.

    * `:vendor_client` — `String.t() | nil`, the raw value of the first header
      in `vendor_client_headers/0` the request carries. HTTP only,
      self-reported, and for some callers the only signal separating several
      surfaces of a single vendor that otherwise arrive with identical
      `clientInfo` and `User-Agent`. `nil` for every caller that sets none of
      them, which is most of them.

  The kernel owns the vendor header list rather than asking a host to configure
  it: these names are facts about how particular clients behave on the wire,
  the same kind of fact as a user-agent database, and every host that mounts
  this endpoint would otherwise have to discover and maintain the same list
  independently. Teaching the library one more vendor is a one-line change
  here; it is not something a consumer should have to know about at all.

  Repeated headers report only their first value. A repeated `User-Agent` is an
  upstream that cannot agree with itself, and joining the values would put a
  string on the span that no client ever sent.

  ## `[:mcp, :handler, :start | :stop | :exception]`

  One span per tool call, resource read, prompt get, or argument completion,
  emitted by `MCP.Server` around the handler module. A `:completion` span wraps
  a `complete/3` callback and carries the same metadata as any other: the
  entry being completed is a resource template or a prompt, so its description
  and required scopes are as available there as anywhere else.

    * start measurements — `:system_time`
    * stop/exception measurements — `:duration` (native units)
    * metadata — `:kind` (`:tool`, `:resource`, `:resource_template`,
      `:prompt`, `:completion`), `:name`, `:description`, `:required_scopes`,
      `:principal`, `:client`, `:protocol_version`, `:session_id`, and on stop
      `:outcome`
    * exception metadata — `:kind_of_error`, `:reason`, `:stacktrace`

  `:outcome` is `:ok`, `:error` (the handler returned an error), `:not_found`
  (a read miss, including a 404-status raise), `:input_required` (a tool asked
  for more input), or `:invalid` (the handler returned an unusable shape).
  A read miss is a normal outcome, so it stops rather than raising an
  exception event; only an unhandled raise emits `:exception`.

  `:client`, `:protocol_version`, and `:session_id` mean exactly what they mean
  on the request span and are repeated here on purpose, so that grouping
  handler spans by caller identity, protocol revision, or session needs no join
  back to the request span.

  `:user_agent` and `:vendor_client` are **not** repeated: they come from
  request headers rather than from `MCP.Context`, which is the only thing
  threaded down to a handler. Slicing handler latency by client build or vendor
  surface therefore does still require joining to the request span on
  `:session_id`. That is a real gap rather than a deliberate omission — it is
  simply the boundary of what the context currently carries.

  ### Entry metadata

    * `:description` — `String.t() | nil`, the declared description of the tool,
      resource, template, or prompt being invoked. Carried on the span because
      the alternative is for an observer to reach back into the server module
      by name to recover it — a layering inversion that also goes wrong the
      moment a name is reused across servers or a module is renamed. `nil` when
      the definition declares none.

    * `:required_scopes` — `[String.t()]`, the scopes the entry demands. It is
      the natural key for grouping handlers by sensitivity, since what a thing
      demands is the closest the kernel comes to a statement of what it can
      reach.

      This and `:granted_scopes` are deliberately not both called `:scopes`.
      They answer different questions — one is about a caller, the other about
      a definition — and the only thing relating them on a handler span is that
      the handler ran at all, which means the granted list covered the required
      one. `events/0` hands a host all six events for a single
      `:telemetry.attach_many/4`, so under a shared name the obvious
      implementation — one handler function tagging on `metadata[:scopes]` —
      would blend two unrelated lists into one meaningless dimension with
      nothing raising anywhere. Distinct names make that mistake impossible to
      write rather than merely documented against. The precedent is Ecto's, in
      this project's own dependency tree: where one concept occurs several
      times it qualifies every instance (`query_time`, `queue_time`,
      `decode_time`, `idle_time`) rather than leaving one of them bare.

  ## Session identifier

  `:session_id` is a correlation label and nothing more: nothing in the kernel
  reads it, branches on it, or stores anything under it.

  It is resolved per request by `MCP.Plug`, in this order:

    1. The `Mcp-Session-Id` request header, if the caller sent a usable one.
    2. `instance_id/0`, this node's own identifier.

  On that path it is always a `String.t()`. Like `:protocol_version`, it is
  `nil` only for an `MCP.Context` a host builds itself and hands to
  `MCP.Server.dispatch/4` — no conn exists there to resolve it from, and
  inventing one would put a fresh identifier on every call, which is worse than
  an honest `nil`. A host driving `dispatch/4` directly and wanting the field
  populated should set `:session_id` on the context it builds.

  A caller-supplied value is used only if it is plausibly an identifier: at
  most 128 bytes, and visible ASCII throughout. A value failing either test is
  treated as no value at all and falls through to `instance_id/0`, keeping the
  field always present on the plug path.

  Be clear about what that check does and does not buy, because it is easy to
  read more into it. It bounds the damage any *single* value can do to a host
  that logs or tags with it. It does **not** bound how many *distinct* values
  arrive: a caller sending a fresh random identifier on every request still
  produces unbounded distinct values, and with `allow_anonymous: true` that
  caller need not have authenticated at all. So do not use `:session_id`
  directly as a metric label or a metric tag. Bucket it, hash it into a fixed
  space, or use it only where unbounded distinct values are expected — a log
  correlation field, a trace attribute, a join key in a store that already
  handles high cardinality. The kernel cannot make that choice for you: it does
  not know your metrics backend, and silently collapsing the value would break
  the correlation the field exists for.

  The chain is short because this protocol revision left it nothing longer to
  draw on. The 2026-07-28 spec is stateless by design: it removed the
  `initialize` handshake and protocol-level sessions outright, and it defines
  no conversation, session, or correlation key in `_meta` — `protocolVersion`,
  `clientInfo`, `clientCapabilities`, `logLevel`, `subscriptionId`, and the W3C
  trace-context keys are the whole reserved set, and none of them groups a
  caller's requests over time. There is simply no client-supplied session
  identifier to read on a conforming modern request.

  Reading `Mcp-Session-Id` at all deserves its own justification, because the
  spec tells a server of this revision to ignore that header and to neither
  mint nor echo session IDs. The kernel obeys all of that: it never issues a
  session ID, never returns one, never keys state on one, and never treats its
  presence as establishing anything. What is left is a string a pre-2026-07-28
  client volunteered, and for the single purpose of grouping that client's own
  requests it is better evidence than this node's identity is — so it is passed
  through as an opaque label and nothing more. Hosts that would rather not see
  legacy values at all can ignore the field and use `instance_id/0` directly.

  The value is emitted as a plain opaque string in whatever form it arrives.
  The kernel does not prefix, hash, or reformat it; a consumer that needs a
  particular shape should derive it on its own side, where the requirement
  actually lives.

  Grouping by `instance_id/0` is the weakest link in the chain and worth being
  honest about: it groups every anonymous caller on a node together, and it
  splits one caller's requests across nodes behind a load balancer. It is a
  floor that keeps the field always present, not a real session.
  """

  @instance_key {__MODULE__, :instance_id}

  # Order is precedence, so put the more specific header first if two vendors
  # ever overlap. A name earns a place here only when the vendor documents it;
  # guessing one is worse than leaving `:vendor_client` nil, because a wrong
  # name reads as "this caller sent nothing" and is indistinguishable from the
  # truth. As of this release exactly one vendor documents such a header --
  # OpenAI, for one, documents none, and a ChatGPT connector is identified
  # through `:client` and `:user_agent` instead.
  @vendor_client_headers ["x-anthropic-client"]

  @doc "Every event the kernel emits, for `:telemetry.attach_many/4`."
  def events do
    [
      [:mcp, :request, :start],
      [:mcp, :request, :stop],
      [:mcp, :request, :exception],
      [:mcp, :handler, :start],
      [:mcp, :handler, :stop],
      [:mcp, :handler, :exception]
    ]
  end

  @doc """
  Request headers checked, in order, to populate `:vendor_client` — the first
  one present on the request wins.

  Exposed so a host can see what the kernel looks for without reading its
  source, and so a test can assert against the same list the plug consults.
  It is deliberately not configurable: see the note above on why the library
  carries this rather than the consumer.
  """
  def vendor_client_headers, do: @vendor_client_headers

  @doc """
  This node's instance identifier: an opaque random string, generated on first
  use and stable for the life of the VM.

  It is the last link of the `:session_id` chain described above, and it is
  deliberately *not* derived from anything — not the node name, not the host,
  not a boot timestamp. A derived identifier would be reproducible by anything
  that knows the inputs, and this value ends up in a host's analytics store
  where a reproducible identifier invites being treated as a join key onto the
  deployment itself.

  Held in `:persistent_term`, so reads are free and no process owns it — the
  kernel starts no supervision tree, and a telemetry identifier that needed one
  would be a strange thing for a library to demand. The cost is paid on write
  instead: `:persistent_term.put/2` scans every process in the VM, so the write
  is deliberately once-ever rather than per request.

  Two processes racing the very first call can each observe a different value
  before the term settles, and each loser of that race pays its own VM-wide
  scan — so a cold node taking a burst of concurrent first requests can pay
  several in a row. The window is one burst wide, on a node that has served no
  requests yet.

  `@on_load` would close it with neither a process nor a lock, and is the
  obvious fix; it is not used here because a raise inside `@on_load` makes the
  module permanently unloadable, which turns a bounded startup hiccup into a
  library that cannot be loaded at all. That trade is not worth taking for a
  telemetry identifier, but it is the right fix if this ever costs more than it
  appears to.
  """
  def instance_id do
    case :persistent_term.get(@instance_key, nil) do
      nil ->
        :persistent_term.put(@instance_key, generate_instance_id())
        :persistent_term.get(@instance_key)

      id ->
        id
    end
  end

  defp generate_instance_id, do: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
end
