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

    - lag (subscribe late — seed from the store on boot, PM3)
    - catch up (replay the log through the same pure fold)
    - merge by union (the index is append-only by construction)

  ...which is exactly what makes cross-instance federation and loam-overflow
  indexes a later-loop drop-in (PLAN.md §2).

  Lifecycle (fable-5 P5, PR #8):

    - `seed_from_set: true` (default): init ATOMICALLY seeds + subscribes
      (`DurableStore.subscribe_seeded/1` — one serialized store call, so
      there is no commit gap between the seed snapshot and the feed
      registration). The server MONITORS the store: on a restart it
      re-attaches + re-seeds with a bounded retry (50ms x 100), and STOPS
      LOUDLY (`{:stop, :store_unavailable}`) if the budget is exhausted —
      a permanently-detached server serving stale answers is worse than a
      crash (P5 medium).
    - `seed_from_set: false`: a BLIND view — starts empty and sees only
      deltas delivered AFTER it attaches. The contract, stated exactly
      (fable-5 P5 round 3 — doc and behavior must agree): feed-only during
      NORMAL operation — it never rebuilds from the full history just
      because a delta arrives. On STORE RESTART recovery, however, it
      re-seeds from the set, because deltas committed in the gap between
      the store reboot and the re-subscribe cannot be reconstructed from
      the feed alone — a view that missed the gap has no way to know what
      it missed, and a silently-incomplete index is worse than a seeded
      one. "Blind" is a startup/steady-state posture, not a guarantee that
      survives a store crash.
  """

  use GenServer

  alias Kyber.{DurableIndex, DurableStore}

  # P5: bounded re-attach retries after a store restart (50ms cadence x 100
  # = up to 5s; the store restart is supervised and fast)
  @max_attach_retries 100
  @attach_timeout 10_000

  @type t :: %__MODULE__{
          index: DurableIndex.t(),
          seed_from_set: boolean(),
          # true iff subscribed to the store feed (false for a blind view,
          # or after a failed re-attach — see handle_info clauses)
          attached: boolean(),
          store_ref: reference() | nil,
          retries: non_neg_integer()
        }

  defstruct index: DurableIndex.new(),
            seed_from_set: false,
            attached: false,
            store_ref: nil,
            retries: 0

  @doc """
  Start an index server. Options:

    - `:seed_from_set` (default `true`) — seed the view from the store's
      current set AND subscribe, ATOMICALLY (one `subscribe_seeded/1`
      call). `false` starts a BLIND view (empty, feed-only, never
      converted to full-history).
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

    # ALWAYS monitor the store (both modes — P5 medium: a blind or
    # attach/1-only subscriber whose registration died with the store would
    # otherwise lose the feed forever on a restart). The DOWN handler
    # re-subscribes; seeded views also re-seed (a seeded init starts from
    # the empty index; the atomic subscribe_seeded call folds the set in).
    case safe_subscribe(seed_from_set, DurableIndex.new()) do
      {:ok, index, ref} ->
        {:ok,
         %__MODULE__{
           index: index,
           seed_from_set: seed_from_set,
           attached: true,
           store_ref: ref,
           retries: 0
         }}

      :unavailable ->
        # fail at boot: a server that cannot reach the store cannot be a
        # reliable index (P5 medium — dead code error branches)
        {:stop, :store_unavailable}
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
  # a BLIND view (seed_from_set: false) stays blind: it only ever adds the
  # deltas the feed delivers after attach — never rebuilds from the full
  # history (P5 medium — silent conversion to full-history was a contract
  # violation)
  def handle_info({:delta, id, claims}, %{seed_from_set: false} = state) do
    {:noreply, %{state | index: DurableIndex.add(state.index, %{id: id, claims: claims})}}
  end

  # an ATTACHED seeded view receiving a delta it has not yet re-synced
  # from: the store is back (it is delivering), so re-attach + re-seed to
  # be sure the view is current (P5 — a detached view is incomplete, not
  # blind)
  def handle_info({:delta, id, claims}, %{attached: false} = state) do
    case safe_subscribe(state.seed_from_set, state.index) do
      {:ok, index, ref} ->
        {:noreply, %{state | index: index, attached: true, store_ref: ref, retries: 0}}

      :unavailable ->
        # store vanished mid-flight; fold the delta in for now, the DOWN
        # (or a later retry) will re-sync
        {:noreply, %{state | index: DurableIndex.add(state.index, %{id: id, claims: claims})}}
    end
  end

  def handle_info({:delta, id, claims}, state) do
    {:noreply, %{state | index: DurableIndex.add(state.index, %{id: id, claims: claims})}}
  end

  # the store restarted: subscriptions are store-owned state and do not
  # survive a restart, so re-subscribe AND re-seed (P5 medium: a silent
  # permanent staleness is worse than a re-sync). Recovery ALWAYS re-seeds
  # from the set — even a blind view — because deltas committed in the gap
  # between the store reboot and the re-subscribe are otherwise lost
  # forever; a view that missed the gap has no way to know what it missed.
  # (The blind contract governs normal operation: a seed_from_set: false
  # init starts empty and only folds feed deltas. Recovery is not normal
  # operation.) The DOWN arrives DURING the stop window, before the
  # supervised restart has booted the new store — so if the store is not up
  # yet, retry with a bounded send_after.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{store_ref: ref} = state) do
    case safe_subscribe(true, state.index) do
      {:ok, index, new_ref} ->
        {:noreply, %{state | index: index, attached: true, store_ref: new_ref, retries: 0}}

      :unavailable ->
        # schedule the FIRST retry immediately (the retry_attach handler
        # chains the rest)
        Process.send_after(self(), :retry_attach, 50)
        {:noreply, %{state | attached: false, store_ref: nil, retries: 1}}
    end
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  def handle_info(:retry_attach, %{attached: true} = state) do
    # stale timer from a re-attach that has since succeeded — ignore it
    # (P5 low: redundant full re-seeds)
    {:noreply, state}
  end

  def handle_info(:retry_attach, state) do
    case safe_subscribe(true, state.index) do
      {:ok, index, new_ref} ->
        {:noreply, %{state | index: index, attached: true, store_ref: new_ref, retries: 0}}

      :unavailable ->
        if state.retries < @max_attach_retries do
          Process.send_after(self(), :retry_attach, 50)
          {:noreply, %{state | retries: state.retries + 1}}
        else
          # P5 medium: a permanently-detached server serving stale answers
          # is worse than a crash — stop loudly
          require Logger

          Logger.error(
            "kyber: IndexServer could not re-attach to the store after #{@max_attach_retries} tries — stopping"
          )

          {:stop, :store_unavailable, state}
        end
    end
  end

  # anything else (e.g. a stray message) is ignored, never a crash
  def handle_info(_other, state) do
    {:noreply, state}
  end

  # one (re-)subscribe attempt, mode-aware: a seeded view wants the ATOMIC
  # seed+subscribe (one store call, no commit gap) — the set is folded into
  # a fresh index; a blind view just re-subscribes, KEEPING its existing
  # (feed-only) index (`current_index` is returned unchanged). The store's
  # calls EXIT on a real outage (noproc / call timeout) — they never return
  # {:error, _}, so wrap them (P5 medium: the old {:error, _} branches were
  # dead code and the server crashed on exactly the restart path it claimed
  # to survive).
  defp safe_subscribe(seed_from_set, current_index) do
    store_pid = Process.whereis(DurableStore)

    if store_pid do
      try do
        result =
          if seed_from_set do
            GenServer.call(DurableStore, {:subscribe_seeded, self()}, @attach_timeout)
          else
            GenServer.call(DurableStore, {:subscribe, self()}, @attach_timeout)
          end

        case result do
          {:ok, set} -> {:ok, DurableIndex.build(set), Process.monitor(store_pid)}
          :ok -> {:ok, current_index, Process.monitor(store_pid)}
          _other -> :unavailable
        end
      catch
        :exit, _reason -> :unavailable
      end
    else
      :unavailable
    end
  end
end
