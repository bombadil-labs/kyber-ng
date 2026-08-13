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

  # P5: bounded re-attach retries after a store restart (50ms cadence x 100
  # = up to 5s; the store restart is supervised and fast)
  @max_attach_retries 100

  @type t :: %__MODULE__{
          index: DurableIndex.t(),
          seed_from_set: boolean(),
          store_ref: reference() | nil,
          retries: non_neg_integer()
        }

  defstruct index: DurableIndex.new(), seed_from_set: false, store_ref: nil, retries: 0

  @doc """
  Start an index server. Options:

    - `:seed_from_set` (default `true`) — on boot, ATOMICALLY seed from the
      store and subscribe (one `DurableStore.subscribe_seeded/1` call, so
      there is no commit gap between the seed snapshot and the feed
      registration — fable-5 P5 medium). The server also MONITORS the
      store: on a store restart it re-attaches and re-seeds automatically
      (P5 medium — subscriptions do not survive a store restart).
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

    if seed_from_set do
      # ATOMIC seed+attach (P5 fix): one store call returns the snapshot AND
      # registers us, so no delta committed between the two is lost. We then
      # monitor the store so a restart re-attaches + re-seeds us (P5 medium).
      case DurableStore.subscribe_seeded(self()) do
        {:ok, set} ->
          ref = Process.monitor(Process.whereis(DurableStore))
          {:ok, %__MODULE__{index: DurableIndex.build(set), seed_from_set: true, store_ref: ref}}

        {:error, _reason} ->
          {:stop, :store_not_running}
      end
    else
      {:ok, %__MODULE__{index: DurableIndex.new(), seed_from_set: false, store_ref: nil}}
    end
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
  def handle_info({:delta, id, claims}, %{store_ref: nil} = state) do
    # store is back and delivering; re-attach to be sure the view is current
    case reattach() do
      {:ok, set, new_ref} ->
        {:noreply, %{state | index: DurableIndex.build(set), store_ref: new_ref}}

      :retry ->
        {:noreply, %{state | index: DurableIndex.add(state.index, %{id: id, claims: claims})}}
    end
  end

  def handle_info({:delta, id, claims}, state) do
    {:noreply, %{state | index: DurableIndex.add(state.index, %{id: id, claims: claims})}}
  end

  # the store restarted: subscriptions are store-owned state and do not
  # survive a restart, so re-attach + re-seed atomically (P5 medium — a
  # silent permanent staleness is worse than a re-sync). The DOWN arrives
  # DURING the stop window, before the supervised restart has booted the new
  # store — so if the store is not up yet, retry with a bounded send_after
  # (the store restart is supervised and fast).
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{store_ref: ref} = state) do
    case reattach() do
      {:ok, set, new_ref} ->
        {:noreply, %{state | index: DurableIndex.build(set), store_ref: new_ref}}

      :retry ->
        # schedule the FIRST retry immediately (the retry_attach handler
        # chains the rest); without this the server would wait forever
        Process.send_after(self(), :retry_attach, 50)
        {:noreply, %{state | store_ref: nil, retries: 1}}
    end
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  def handle_info(:retry_attach, state) do
    case reattach() do
      {:ok, set, new_ref} ->
        {:noreply, %{state | index: DurableIndex.build(set), store_ref: new_ref}}

      :retry ->
        if state.retries < @max_attach_retries do
          Process.send_after(self(), :retry_attach, 50)
          {:noreply, %{state | retries: state.retries + 1}}
        else
          # give up loudly rather than silently stale (P5 medium)
          require Logger

          Logger.warning(
            "kyber: IndexServer could not re-attach to the store after #{@max_attach_retries} tries"
          )

          {:noreply, %{state | store_ref: nil}}
        end
    end
  end

  # anything else (e.g. a stray message) is ignored, never a crash
  def handle_info(_other, state) do
    {:noreply, state}
  end

  # one re-attach attempt: succeeds iff the store is registered
  defp reattach do
    if Process.whereis(DurableStore) do
      case DurableStore.subscribe_seeded(self()) do
        {:ok, set} -> {:ok, set, Process.monitor(Process.whereis(DurableStore))}
        {:error, _reason} -> :retry
      end
    else
      :retry
    end
  end
end
