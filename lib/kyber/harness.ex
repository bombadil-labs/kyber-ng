defmodule Kyber.Harness do
  @moduledoc """
  The loop (spec/05-harness.md): a source event in -> a signed claim persisted
  -> a materialized view out, run against the app-started durable store (no
  new process — `Kyber.DurableStore` is the sink). `ingest/2` is the human
  half (`message.received`, signed by the HUMAN key); `agent_event/2` is the
  response half (`message.sent`, signed by the AGENT key). Both funnel through
  the same pipeline: load seed -> `Events` builder -> `Wire.envelope/1` ->
  `DurableStore.append/1` -> `{:ok, id}`. A refused delta returns the door's
  reason unchanged.

  The SOURCE interface is an injectable plain map — a plugin adapter later
  sits in front of it (the real transport is gated on the substrate L4
  reactor). The shape is pinned (T4 rev 2): REQUIRED binary keys plus an
  optional `"ts"` (float-ms, D14; default = now as float ms). Malformed input
  is refused with a tagged tuple, never a crash: a missing required key ->
  `{:error, {:missing_key, :source, key}}`; an unknown key ->
  `{:error, {:unknown_key, :source, key}}` (closed envelope — reject, never
  repair; nothing extra can be smuggled into claims). Validation is defensive
  `Map.fetch`/`Map.get` — a destructuring pattern match is FORBIDDEN (it would
  raise MatchError instead of a tagged tuple).

  The store-down guard comes FIRST: with :kyber stopped the pipeline answers
  `{:error, :store_not_running}` instead of a bare `GenServer.call` raising
  `exit(:noproc)` (DurableStore.append/1 has no whereis guard of its own).
  """

  alias Kyber.{DurableStore, Events, Keys, Wire}

  @ingest_required ~w(message_id channel_id session_id content)
  @agent_required ~w(response_delta_id out_message_id channel_id content)
  @optional_key "ts"

  @doc """
  Ingest a human source event: translate to a `message.received` claim signed
  by the human key, persist it, and return `{:ok, envelope_id}`.
  """
  @spec ingest(map(), Path.t()) :: {:ok, String.t()} | {:error, term()}
  def ingest(source_event, keyring_dir) when is_map(source_event) do
    with :ok <- guard_store(),
         {:ok, source} <- validate_source(source_event, @ingest_required),
         {:ok, human_seed} <- Keys.load_human_seed(keyring_dir),
         {:ok, signed} <-
           Events.message_received(
             human_seed,
             timestamp(source),
             Map.get(source, "message_id"),
             Map.get(source, "channel_id"),
             Map.get(source, "session_id"),
             Map.get(source, "content")
           ) do
      persist(signed)
    end
  end

  def ingest(_, _), do: {:error, :malformed_source}

  @doc """
  The response half: a model event -> a `message.sent` claim signed by the
  AGENT key, persisted, `{:ok, envelope_id}` — same pipeline and the same
  required/optional/unknown-key contract as `ingest/2`.
  """
  @spec agent_event(map(), Path.t()) :: {:ok, String.t()} | {:error, term()}
  def agent_event(model_event, keyring_dir) when is_map(model_event) do
    with :ok <- guard_store(),
         {:ok, source} <- validate_source(model_event, @agent_required),
         {:ok, agent_seed} <- Keys.load_agent_seed(keyring_dir),
         {:ok, signed} <-
           Events.message_sent(
             agent_seed,
             timestamp(source),
             Map.get(source, "response_delta_id"),
             Map.get(source, "out_message_id"),
             Map.get(source, "channel_id"),
             Map.get(source, "content")
           ) do
      persist(signed)
    end
  end

  def agent_event(_, _), do: {:error, :malformed_source}

  @doc """
  The materialized view (rev 2 pin): `DurableStore.set()` holds
  `id_hex => {claims, sig}` (atom-keyed claims, NOT wire envelopes); `view/0`
  returns the LIST of the atom-keyed claim maps, sorted by id_hex
  (`Enum.sort_by` — deterministic, so view equality is assertable).
  """
  @spec view() :: [map()]
  def view do
    DurableStore.set()
    |> Enum.sort_by(fn {id_hex, _claims} -> id_hex end)
    |> Enum.map(fn {_id_hex, {claims, _sig}} -> claims end)
  end

  # ---------------------------------------------------------------- helpers

  # the store-down guard FIRST — a bare DurableStore.append/1 would raise
  # exit(:noproc) here (T2 made the app the store's owner); mirror
  # Store.append/1's whereis guard so the answer is a tagged tuple
  defp guard_store do
    if Process.whereis(DurableStore), do: :ok, else: {:error, :store_not_running}
  end

  # pinned source contract: REQUIRED keys present, UNKNOWN keys refused.
  # Defensive Map.fetch — never a destructuring pattern match (MatchError is
  # forbidden: any error must be a tagged tuple, never a crash).
  defp validate_source(event, required) do
    with :ok <- check_required(event, required),
         :ok <- check_unknown(event, required ++ [@optional_key]) do
      {:ok, event}
    end
  end

  defp check_required(event, required) do
    Enum.reduce_while(required, :ok, fn key, :ok ->
      case Map.fetch(event, key) do
        {:ok, _value} -> {:cont, :ok}
        :error -> {:halt, {:error, {:missing_key, :source, key}}}
      end
    end)
  end

  defp check_unknown(event, allowed) do
    case Map.keys(event) -- allowed do
      [] -> :ok
      [unknown | _] -> {:error, {:unknown_key, :source, unknown}}
    end
  end

  # optional "ts" (float-ms, D14): present -> passed to the builder untouched
  # (the builder is the one coercion point for explicit integer args — the
  # harness never coerces); absent -> now as float ms
  defp timestamp(source) do
    case Map.fetch(source, @optional_key) do
      {:ok, ts} -> ts
      :error -> 1.0 * System.system_time(:millisecond)
    end
  end

  defp persist(signed) do
    envelope = Wire.envelope(signed)

    case DurableStore.append(envelope) do
      :ok -> {:ok, envelope["id"]}
      {:error, _reason} = err -> err
    end
  end
end
