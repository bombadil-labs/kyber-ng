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

  T11b (carried contract addition 1): every builder appends a `type`
  declaration pointer (`{:entity, TypeName, "instances"}` — the T11a
  convention) so its output validates TYPED at the daemon's door. The
  declaration rides LAST: the kind marker (the template's leading role) is
  what the gather routes on, so the leading pointer must stay the template's.
  """

  alias Rhizomatic.Delta
  alias Kyber.Keys

  @type claims :: Delta.claims()
  @type signed :: {claims(), String.t()}

  @doc """
  `message.received` — a human (or remote) message arrives (spec/01-events.md
  §2.1). Author: the human's key. Pointers: received / at / by / content /
  session, plus T14j (C2) the OPTIONAL `discordUser` STRING pointer
  (`"discord:user:" <> author_id`; `nil` omits it ENTIRELY — the /7 nil arm
  is byte-identical to /6, no `%{role: "discordUser", target: nil}`
  residue). The role is `discordUser`, NEVER `author` (the compiler's
  merge-over would overwrite the signer). Missing / whitespace-only authors
  mint nil (fail-closed).
  """
  @spec message_received(
          String.t(),
          number(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t() | nil
        ) :: {:ok, signed()} | {:error, term()}
  def message_received(human_seed_hex, ts, message_id, channel_id, session_id, content, discord_user \\ nil) do
    with {:ok, ts} <- timestamp(ts),
         {:ok, author} <- author_for(human_seed_hex) do
      claims = %{
        timestamp: ts,
        author: author,
        pointers:
          List.flatten([
            %{role: "received", target: {:entity, message_id, "incoming"}},
            %{role: "at", target: {:entity, channel_id, "messages"}},
            %{role: "by", target: {:entity, human_entity_id(author), "sent"}},
            %{role: "content", target: {:string, content}},
            %{role: "session", target: {:entity, session_id, "messages"}},
            if(discord_user, do: [%{role: "discordUser", target: {:string, discord_user}}], else: []),
            type("MessageReceived")
          ])
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
          %{role: "notes", target: {:string, notes}},
          type("PromptAnnotated")
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
          %{role: "usage", target: {:entity, "agent:kyber", "tokens"}},
          type("LlmResponse")
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
          %{role: "caused_by", target: {:delta, response_delta_id, nil}},
          type("MessageSent")
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
          %{role: "during", target: {:delta, during_delta_id, "tool_use"}},
          type("ToolInvoked")
        ]
      }

      signed(claims, agent_seed_hex)
    end
  end

  # ---------------------------------------------------------------- helpers

  # the T11a type declaration (carried addition 1) — always the LAST pointer;
  # the leading role stays the kind marker the gather routes on
  defp type(name), do: %{role: "type", target: {:entity, name, "instances"}}

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
