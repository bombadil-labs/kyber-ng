defmodule Kyber.IndexServer do
  @moduledoc """
  T16 (F3) — the spawnable, federatable index server: a GenServer holding
  its own `Kyber.DurableIndex` projection, fed by the `DurableStore`
  subscribe seam (F2).

  This is the rhizomatic fork point: spin up one per container, per
  hyperview, per differently-tuned query — each is an ISOLATED process
  maintaining its own derived map from the SAME append feed, with zero
  coupling to the store's in-process index (F1). Because the store only
  learns, every index is a downstream projection that can:

    - lag (subscribe late — seed from `DurableStore.set/0` on boot, PM3)
    - catch up (replay the log through the same pure fold)
    - merge by union (the index is append-only by construction)

  ...which is exactly what makes cross-instance federation and loam-overflow
  indexes a later-loop drop-in (PLAN.md §2).

  Contract: the store SENDS `{:delta, id, claims}` (plain `send/2`, not a
  GenServer cast) — handled in `handle_info/2`, not `handle_cast`.
  """

  use GenServer

  alias Kyber.{DurableIndex, DurableStore}

  @type t :: %__MODULE__{
          index: DurableIndex.t(),
          seed_from_set: boolean()
        }

  defstruct index: DurableIndex.new(), seed_from_set: false

  @doc """
  Start an index server. Options:

    - `:seed_from_set` (default `true`) — on boot, replay `DurableStore.set/0`
      through the pure fold so a LATE subscriber catches up with everything
      that happened before it subscribed (PM3: replay and live appends use
      the SAME `DurableIndex.add/2`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Has the message (by id) been answered per this view?"
  @spec answered?(pid(), String.t()) :: boolean()
  def answered?(server, msg_id) do
    GenServer.call(server, {:answered?, msg_id})
  end

  @doc "Is `content` an open duplicate per this view?"
  @spec open_duplicate?(pid(), String.t(), non_neg_integer()) :: boolean()
  def open_duplicate?(server, content, window_ms) do
    GenServer.call(server, {:open_duplicate?, content, window_ms})
  end

  @doc "The view's message count (boundedness observable)."
  @spec message_count(pid()) :: non_neg_integer()
  def message_count(server) do
    GenServer.call(server, :message_count)
  end

  @doc "Subscribe this server to the store feed (idempotent)."
  @spec attach(pid()) :: :ok
  def attach(server) do
    DurableStore.subscribe(server)
  end

  @impl true
  def init(opts) do
    seed_from_set = Keyword.get(opts, :seed_from_set, true)
    index = if seed_from_set, do: DurableIndex.build(DurableStore.set()), else: DurableIndex.new()
    {:ok, %__MODULE__{index: index, seed_from_set: seed_from_set}}
  end

  @impl true
  def handle_call({:answered?, msg_id}, _from, state) do
    {:reply, DurableIndex.answered?(state.index, msg_id), state}
  end

  def handle_call({:open_duplicate?, content, window_ms}, _from, state) do
    now = System.system_time(:millisecond)
    {:reply, DurableIndex.open_duplicate?(state.index, content, now, window_ms), state}
  end

  def handle_call(:message_count, _from, state) do
    {:reply, DurableIndex.message_count(state.index), state}
  end

  @impl true
  def handle_info({:delta, id, claims}, state) do
    {:noreply, %{state | index: DurableIndex.add(state.index, %{id: id, claims: claims})}}
  end

  # anything else (e.g. a stray message) is ignored, never a crash
  def handle_info(_other, state) do
    {:noreply, state}
  end
end
