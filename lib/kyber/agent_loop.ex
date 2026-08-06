defmodule Kyber.AgentLoop do
  @moduledoc """
  The runtime agent loop (T10, AC4): the built-in handler pair —
  `message.received` in, deterministic `message.sent` out.

  The handler is a PURE `(delta[]) -> delta[]` function: no IO, no boot, no
  side effects beyond returning the signed response delta. The agent seed is
  captured as a VALUE at subscription time (the daemon did the keyring IO at
  boot); the clock is injectable so tests can pin the timestamp.

  The response claim is NEW: role `message`, flavor `sent`; its origin is
  the received claim's id (the `caused_by` pointer); its content is the
  pinned deterministic reply `ack <received-id>`; it is signed with the
  daemon's agent key — the door verifies it on persist like any claim.

  The match is structural: the FIRST pointer's role discriminates
  `message.received` ("received") from `message.sent` ("sent"), so the agent
  loop can never be its own subscriber (AC2 — no loops).
  """

  alias Kyber.Events
  alias Rhizomatic.Delta

  @subscription_id :agent_loop

  @doc "The gather subscription id of the built-in agent loop."
  @spec subscription_id() :: atom()
  def subscription_id, do: @subscription_id

  @doc """
  The `{match, handler}` pair the daemon subscribes to the gather. Options:
  `:now` — a zero-arity float-ms clock (default: system time), injectable
  for deterministic tests.
  """
  @spec subscription(String.t(), keyword()) ::
          {(Rhizomatic.Delta.claims() -> boolean()),
           ([Rhizomatic.Delta.claims()] -> [Kyber.Events.signed()])}
  def subscription(agent_seed, opts \\ []) do
    now = Keyword.get(opts, :now, fn -> 1.0 * System.system_time(:millisecond) end)
    {match_received(), handler(agent_seed, now)}
  end

  @doc "The pinned deterministic reply text (AC4): `ack <received-id>`."
  @spec reply_text(String.t()) :: String.t()
  def reply_text(received_id), do: "ack " <> received_id

  # role `message`, flavor `received`: the FIRST pointer's role is the
  # discriminator — `message.sent`'s first role is "sent"
  defp match_received do
    fn claims ->
      case List.first(claims.pointers) do
        %{role: "received"} -> true
        _ -> false
      end
    end
  end

  defp handler(agent_seed, now) do
    fn [received | _rest] ->
      received_id = Delta.id_hex(received)

      case Events.message_sent(
             agent_seed,
             now.(),
             received_id,
             out_message_id(received_id),
             channel_of(received),
             reply_text(received_id)
           ) do
        {:ok, signed} -> [signed]
        {:error, _reason} -> []
      end
    end
  end

  defp out_message_id(received_id), do: "ack-" <> received_id

  # reply via the channel the message arrived on (the received claim's "at"
  # pointer); a claim without one still gets a well-formed response
  defp channel_of(claims) do
    Enum.find_value(claims.pointers, "unknown", fn
      %{role: "at", target: {:entity, id, _ctx}} -> id
      _pointer -> nil
    end)
  end
end
