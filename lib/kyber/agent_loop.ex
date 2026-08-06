defmodule Kyber.AgentLoop do
  @moduledoc """
  The built-in runtime agent loop (T10 AC4): `message.received` in →
  deterministic `message.sent` out. `handler/1` returns a pure
  `(delta[]) -> delta[]` function — no IO, no boot, no side effect beyond
  the returned response wires; the daemon subscribes it to role `"received"`.

  The response is pinned: a new `message.sent` claim (kind marker `"sent"`),
  `caused_by` pointing back at the received claim's id, `via` the received
  claim's `at` channel, content exactly `ack <received-id>`, signed with the
  daemon's agent key (`Kyber.Events.message_sent/6` — the same template every
  other `message.sent` uses).

  **Determinism outranks clock honesty here (rev 2 pin):** the response
  claims the RECEIVED claim's timestamp and derives its outgoing message id
  (`message:ack:<received-id>`), so the whole response is a pure function of
  the input view. Same view, same claims, same content address — a crash-
  window re-fire (AC3) produces the identical delta and dedupes at the sink
  by construction. A real LLM plugin would claim `now`; the built-in ack
  trades that for idempotence.

  A received claim with no `at` pointer yields no response (reject, never
  repair — the loop never invents a channel to reply on).
  """

  alias Kyber.{Events, Gather, Wire}

  @doc "The pure handler closure over the daemon's agent seed."
  @spec handler(String.t()) :: Gather.handler()
  def handler(agent_seed_hex) do
    fn view -> Enum.flat_map(view, &respond(&1, agent_seed_hex)) end
  end

  # ---------------------------------------------------------------- the ack

  defp respond(%{id: received_id, claims: claims}, seed) do
    with {:ok, channel_id} <- channel_of(claims),
         {:ok, signed} <-
           Events.message_sent(
             seed,
             claims.timestamp,
             received_id,
             "message:ack:" <> received_id,
             channel_id,
             "ack " <> received_id
           ) do
      [Wire.envelope(signed)]
    else
      _no_channel_or_refused -> []
    end
  end

  defp channel_of(%{pointers: pointers}) do
    case Enum.find(pointers, &(&1.role == "at")) do
      %{target: {:entity, id, _ctx}} -> {:ok, id}
      _ -> :error
    end
  end
end
