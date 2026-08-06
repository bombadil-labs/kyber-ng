defmodule Kyber.Events do
  @moduledoc """
  Claim templates for the core kyber events (spec/01-events.md §2). Each
  builder returns `{:ok, {claims, sig_hex}}`: the in-memory claims form the
  witness validates, plus the lowercase-hex Ed25519 signature by the emitting
  author's key (human-origin events by the human key, agent-origin events by
  the agent key).

  Timestamps are **float milliseconds** (D14): explicit integer args are
  converted by the builder itself — never coerced inside the witness. Pointer
  structures are exactly spec/01-events.md §2, emitted in template order
  (array order is part of the content address).
  """

  alias Rhizomatic.Delta
  alias Kyber.Keys

  @type claims :: Delta.claims()
  @type signed :: {claims(), String.t()}

  @doc """
  `message.received` — a human (or remote) message arrives (spec/01-events.md
  §2.1). Author: the human's key. Pointers: received / at / by / content /
  session.
  """
  @spec message_received(String.t(), number(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, signed()} | {:error, term()}
  def message_received(human_seed_hex, ts, message_id, channel_id, session_id, content) do
    with {:ok, ts} <- timestamp(ts),
         {:ok, author} <- author_for(human_seed_hex) do
      claims = %{
        timestamp: ts,
        author: author,
        pointers: [
          %{role: "received", target: {:entity, message_id, "incoming"}},
          %{role: "at", target: {:entity, channel_id, "messages"}},
          %{role: "by", target: {:entity, human_entity_id(author), "sent"}},
          %{role: "content", target: {:string, content}},
          %{role: "session", target: {:entity, session_id, "messages"}}
        ]
      }

      signed(claims, human_seed_hex)
    end
  end

  @doc """
  `prompt.annotated` — the annotator has saturated the prompt (spec/01-events.md
  §2.2). Author: the agent's key. Pointers: annotates (DeltaRef) / notes.
  """
  @spec prompt_annotated(String.t(), number(), String.t(), String.t()) ::
          {:ok, signed()} | {:error, term()}
  def prompt_annotated(agent_seed_hex, ts, annotated_delta_id, notes) do
    with {:ok, ts} <- timestamp(ts),
         {:ok, author} <- author_for(agent_seed_hex) do
      claims = %{
        timestamp: ts,
        author: author,
        pointers: [
          %{role: "annotates", target: {:delta, annotated_delta_id, "annotated"}},
          %{role: "notes", target: {:string, notes}}
        ]
      }

      signed(claims, agent_seed_hex)
    end
  end

  @doc """
  `llm.response` — the model answered the annotated prompt (spec/01-events.md
  §2.3). Author: the agent's key. Pointers: responds (DeltaRef) / content /
  usage.
  """
  @spec llm_response(String.t(), number(), String.t(), String.t()) ::
          {:ok, signed()} | {:error, term()}
  def llm_response(agent_seed_hex, ts, annotated_delta_id, content) do
    with {:ok, ts} <- timestamp(ts),
         {:ok, author} <- author_for(agent_seed_hex) do
      claims = %{
        timestamp: ts,
        author: author,
        pointers: [
          %{role: "responds", target: {:delta, annotated_delta_id, "answer"}},
          %{role: "content", target: {:string, content}},
          %{role: "usage", target: {:entity, "agent:kyber", "tokens"}}
        ]
      }

      signed(claims, agent_seed_hex)
    end
  end

  @doc """
  `message.sent` — the agent's reply was delivered to the world (spec/01-events.md
  §2.4). Author: the agent's key. Pointers: sent / via / content / caused_by
  (DeltaRef, no context).
  """
  @spec message_sent(String.t(), number(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, signed()} | {:error, term()}
  def message_sent(agent_seed_hex, ts, response_delta_id, out_message_id, channel_id, content) do
    with {:ok, ts} <- timestamp(ts),
         {:ok, author} <- author_for(agent_seed_hex) do
      claims = %{
        timestamp: ts,
        author: author,
        pointers: [
          %{role: "sent", target: {:entity, out_message_id, "outgoing"}},
          %{role: "via", target: {:entity, channel_id, "sent"}},
          %{role: "content", target: {:string, content}},
          %{role: "caused_by", target: {:delta, response_delta_id, nil}}
        ]
      }

      signed(claims, agent_seed_hex)
    end
  end

  @doc """
  `tool.exec` — a tool ran and produced a result (spec/01-events.md §2.5).
  Author: the agent's key. Pointers: tool / args / result / during (DeltaRef).
  """
  @spec tool_exec(String.t(), number(), String.t(), String.t(), String.t(), String.t()) ::
          {:ok, signed()} | {:error, term()}
  def tool_exec(agent_seed_hex, ts, during_delta_id, tool_id, args, result) do
    with {:ok, ts} <- timestamp(ts),
         {:ok, author} <- author_for(agent_seed_hex) do
      claims = %{
        timestamp: ts,
        author: author,
        pointers: [
          %{role: "tool", target: {:entity, tool_id, "invocations"}},
          %{role: "args", target: {:string, args}},
          %{role: "result", target: {:string, result}},
          %{role: "during", target: {:delta, during_delta_id, "tool_use"}}
        ]
      }

      signed(claims, agent_seed_hex)
    end
  end

  @doc """
  `daemon.checkpoint` — the dispatch cursor as data (T10, AC3). Author: the
  daemon's agent key. Pointers: checkpoint (the daemon's cursor entity) /
  cursor (the numeric position). The store is the cursor's only home — a
  re-boot resumes from the latest checkpoint, never from memory alone.
  """
  @spec daemon_checkpoint(String.t(), number(), String.t(), non_neg_integer()) ::
          {:ok, signed()} | {:error, term()}
  def daemon_checkpoint(agent_seed_hex, ts, daemon_id, cursor)
      when is_integer(cursor) and cursor >= 0 do
    with {:ok, ts} <- timestamp(ts),
         {:ok, author} <- author_for(agent_seed_hex) do
      claims = %{
        timestamp: ts,
        author: author,
        pointers: [
          %{role: "checkpoint", target: {:entity, daemon_id, "cursor"}},
          %{role: "cursor", target: {:number, cursor * 1.0}}
        ]
      }

      signed(claims, agent_seed_hex)
    end
  end

  # ---------------------------------------------------------------- helpers

  # validate at the boundary, then sign: reject, never repair
  defp signed(claims, seed_hex) do
    with {:ok, claims} <- Delta.validate(claims),
         {:ok, sig_hex} <- Keys.sign(claims, seed_hex) do
      {:ok, {claims, sig_hex}}
    end
  end

  # D14: the builder is the coercion point for explicit integer args; the
  # witness sees floats only. Exact-f64 check mirrors Rhizomatic.Profile.
  defp timestamp(ts) when is_integer(ts) do
    try do
      f = 1.0 * ts
      if trunc(f) == ts, do: {:ok, f}, else: {:error, {:not_exact_f64, :timestamp}}
    rescue
      ArithmeticError -> {:error, {:not_exact_f64, :timestamp}}
    end
  end

  defp timestamp(ts) when is_float(ts), do: {:ok, ts}
  defp timestamp(_), do: {:error, :timestamp_not_a_number}

  # the "by" target of message.received is the human entity; kyber never mints
  # identities (D2), so it derives from the signing key's public half
  defp human_entity_id("ed25519:" <> pub_hex), do: "human:" <> pub_hex

  defp author_for(seed_hex) do
    case Base.decode16(seed_hex, case: :mixed) do
      {:ok, <<_::binary-32>>} -> {:ok, Keys.author_for_seed(seed_hex)}
      _ -> {:error, :invalid_seed}
    end
  end
end
