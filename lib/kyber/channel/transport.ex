defmodule Kyber.Channel.Transport do
  @moduledoc """
  The transport seam (T14i D1): the 3 pinned callbacks + owner-message
  frames. A transport impl is injected at adapter construction as
  `{module, state}` (the http_client.ex:1-9 precedent — a fake in tests,
  the real impl at the live edge, never a compile-time swap).

  Inbound frames arrive to the owner as `{transport_ref, {:frame, opcode,
  payload}}` where `transport_ref` is whatever `connect/2` returned (the
  impl's pid for both shipped impls). The FRAME is pinned — an unpinned
  seam cannot ride a diff metric; ping(0x9)→pong(0xA) is auto-ponged
  INSIDE the transport impl (the pure codec cannot send, M3), so the
  frame-stream fake observes pongs — exactly why the sends-equal-
  ResponseDelta witness scopes to the delivery seam (H4).

  The real impl (`Kyber.Channel.Transport.Ws`) is a hand-rolled RFC 6455
  client over stdlib `:gen_tcp`/`:ssl` — ZERO new deps; the M13 code-path
  repair (`ensure_http_apps/0` + `otp_ebin_on_path/1`, shared with
  `Kyber.Agent.HttpClient`) is applied before the `:ssl` arm.
  """

  @typedoc "An established connection handle (the impl's pid for both shipped impls)."
  @type conn :: term()

  @doc """
  Establish the connection and hand the owner the frame stream. The impl
  sends `{conn, {:frame, opcode, payload}}` messages to `owner_pid` for
  every inbound data frame; a close (opcode 0x8) frame signals the
  connection ended.
  """
  @callback connect(opts :: keyword(), owner_pid :: pid()) :: {:ok, conn()} | {:error, term()}

  @doc "Send one TEXT frame (the gateway's payloads are JSON text)."
  @callback send_frame(conn :: conn(), payload :: iodata()) :: :ok | {:error, term()}

  @doc "Close the connection cleanly."
  @callback close(conn :: conn()) :: :ok
end
