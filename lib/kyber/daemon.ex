defmodule Kyber.Daemon do
  @moduledoc """
  The operational harness (T10, spec/05-harness.md): the long-lived process
  that makes an agent LIVE in the claims substrate. The loop is
  `event in -> signed claim -> action -> memory`:

    1. a `send_after` TICKER (never `Process.sleep`) polls the durable store
       for claims newer than the dispatch cursor,
    2. each new claim is routed to `Kyber.Gather`, which fires the role-matched
       handlers (the built-in agent loop: `message.received -> message.sent`),
    3. the cursor advances and is recorded as data (a `daemon.checkpoint`
       claim), so a re-boot resumes exactly where it stopped and never re-fires.

  **The dispatch cursor is a lens with state, derived — never a source of
  truth (AC3).** It is the set of claim ids the daemon has routed. It persists
  as `daemon.checkpoint` claims (the recommended shape — state as data); the
  cursor is the UNION of every checkpoint's `dispatched` refs, re-derived from
  the store on boot (merge is union). Even a lagging checkpoint cannot cause a
  re-fire: the built-in handler is DETERMINISTIC and its output is
  content-addressed, so re-running it merges to the same id — a union no-op.
  Pulses fire exactly once by construction (they are never persisted, never
  cursor-tracked); persisted claims fire exactly once through this cursor.

  **The daemon owns a pid/lock (AC1).** `acquire_lock/1` writes `<log>.daemon`
  carrying the OS pid; a second daemon on the same log is refused. A stale lock
  (the daemon was killed) carries a DEAD pid, so the next boot reclaims it —
  a crash never bricks re-boot. `release_lock/1` (run in `terminate/2` on a
  clean SIGTERM shutdown) removes the lock only if it is ours.

  The daemon writes nothing to the world but signed claims: its handler outputs
  and its checkpoints are the only side effects, both recorded in the store
  (D7 — nothing real happens unrecorded). The real `~/.kyber` store is never
  the daemon's target; it runs on the `--log` it is given.
  """

  use GenServer

  alias Kyber.{DurableStore, Events, Gather, Keys, Wire}
  alias Rhizomatic.Delta

  @default_interval_ms 25
  @checkpoint_flavor "checkpoint"
  @received_flavor "received"

  # the shapes tuned DOWN to pulse-only (the admission knob): a heartbeat is
  # ephemeral by nature — it fires handlers but never earns a place in memory
  # (D5). Everything else is persist-everything by default.
  @pulse_only ["tick"]

  # ------------------------------------------------------------------- API

  @doc "The built-in pulse-only shapes (the admission knob's tuned-down set)."
  @spec pulse_only() :: [String.t()]
  def pulse_only, do: @pulse_only

  @doc """
  Start the daemon. Options:

    * `:log_path` — the store the daemon watches (required).
    * `:keyring` — the keyring dir the agent seed is loaded from (required).
    * `:gather` — the gather server (default `Kyber.Gather`).
    * `:auto_tick` — schedule the ticker (default `true`; tests pass `false`
      and drive `tick_now/1`).
    * `:interval` — the ticker period in ms (default `#{@default_interval_ms}`).
    * `:name` — the registered name (default `#{inspect(__MODULE__)}`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Run one dispatch cycle synchronously and return a summary
  `%{routed: n, fired: m}` — the testing seam (deterministic, no timer). The
  ticker calls the same internal cycle.
  """
  @spec tick_now(GenServer.server()) :: %{routed: non_neg_integer(), fired: non_neg_integer()}
  def tick_now(daemon \\ __MODULE__) do
    GenServer.call(daemon, :tick_now)
  end

  # -------------------------------------------------------------- the lock

  @doc "The lock path the daemon owns for `log_path`."
  @spec lock_path(Path.t()) :: Path.t()
  def lock_path(log_path), do: log_path <> ".daemon"

  @doc """
  Acquire the daemon lock for `log_path`. Refuses if a LIVE daemon holds it
  (`{:error, {:already_running, log_path}}`); reclaims a stale lock whose pid
  is dead. Writes this VM's OS pid.
  """
  @spec acquire_lock(Path.t()) :: :ok | {:error, term()}
  def acquire_lock(log_path) do
    lock = lock_path(log_path)

    case File.read(lock) do
      {:ok, content} ->
        if os_alive?(String.trim(content)) do
          {:error, {:already_running, log_path}}
        else
          write_lock(lock)
        end

      {:error, :enoent} ->
        write_lock(lock)

      {:error, reason} ->
        {:error, {:lock_unreadable, reason}}
    end
  end

  @doc "Release the daemon lock for `log_path` — removes it only if it is ours."
  @spec release_lock(Path.t()) :: :ok
  def release_lock(log_path) do
    lock = lock_path(log_path)

    case File.read(lock) do
      {:ok, content} -> if String.trim(content) == System.pid(), do: File.rm(lock)
      _ -> :ok
    end

    :ok
  end

  # ------------------------------------------------------------- callbacks

  @impl true
  def init(opts) do
    # trap exits so terminate/2 runs on a supervisor-initiated (SIGTERM ->
    # init:stop) shutdown and releases the lock cleanly.
    Process.flag(:trap_exit, true)

    log_path = Keyword.fetch!(opts, :log_path)
    keyring = Keyword.fetch!(opts, :keyring)
    gather = Keyword.get(opts, :gather, Gather)
    auto_tick = Keyword.get(opts, :auto_tick, true)
    interval = Keyword.get(opts, :interval, @default_interval_ms)

    with {:ok, agent_seed} <- Keys.load_agent_seed(keyring) do
      Gather.subscribe(gather, @received_flavor, agent_handler(agent_seed))

      state = %{
        log_path: log_path,
        agent_seed: agent_seed,
        gather: gather,
        interval: interval,
        dispatched: derive_cursor()
      }

      if auto_tick, do: schedule(interval)
      {:ok, state}
    else
      {:error, reason} -> {:stop, {:no_agent_seed, reason}}
    end
  end

  @impl true
  def handle_call(:tick_now, _from, state) do
    {summary, state} = dispatch_cycle(state)
    {:reply, summary, state}
  end

  @impl true
  def handle_info(:tick, state) do
    {_summary, state} = dispatch_cycle(state)
    schedule(state.interval)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state), do: release_lock(state.log_path)

  # --------------------------------------------------------- the dispatch

  defp schedule(interval), do: Process.send_after(self(), :tick, interval)

  # one cycle: read the store, route every claim past the cursor (skipping the
  # daemon's own checkpoints — they are bookkeeping, never routed and never
  # self-checkpointed), advance the cursor, and record it as a checkpoint claim.
  defp dispatch_cycle(state) do
    # poll the FILE, not just our own set — the ingested claim may have been
    # appended by another process (the `kyber ingest` VM) on the same --log
    new =
      DurableStore.poll()
      |> Enum.reject(fn {id, {claims, _sig}} ->
        MapSet.member?(state.dispatched, id) or flavor(claims) == @checkpoint_flavor
      end)
      # a deterministic order (content address) so a re-run is byte-stable
      |> Enum.sort_by(fn {id, _delta} -> id end)

    {output_ids, dispatched} =
      Enum.reduce(new, {[], state.dispatched}, fn {id, delta}, {outs, disp} ->
        {:ok, outputs} = Gather.route(state.gather, delta)
        out_ids = Enum.map(outputs, fn {claims, _sig} -> Delta.id_hex(claims) end)
        {outs ++ out_ids, disp |> MapSet.put(id) |> put_all(out_ids)}
      end)

    new_ids = Enum.map(new, fn {id, _delta} -> id end)
    checkpoint_ids = new_ids ++ output_ids

    if checkpoint_ids != [], do: write_checkpoint(state.agent_seed, checkpoint_ids, new)

    {%{routed: length(new_ids), fired: length(output_ids)}, %{state | dispatched: dispatched}}
  end

  defp put_all(set, ids), do: Enum.reduce(ids, set, &MapSet.put(&2, &1))

  # the cursor as data: one checkpoint claim per cycle, referencing exactly the
  # ids dispatched this cycle. The ts is the max among the cycle's inputs (the
  # outputs share it — the handler is deterministic), so the checkpoint is
  # content-stable across a re-derivation.
  defp write_checkpoint(agent_seed, ids, new) do
    ts = new |> Enum.map(fn {_id, {claims, _sig}} -> claims.timestamp end) |> Enum.max()

    with {:ok, signed} <- Events.daemon_checkpoint(agent_seed, ts, ids) do
      DurableStore.append(Wire.envelope(signed))
    end
  end

  # the dispatch cursor, re-derived from the store on boot: the union of every
  # checkpoint claim's `dispatched` refs. NOT in-memory-only (AC3).
  defp derive_cursor do
    DurableStore.poll()
    |> Enum.filter(fn {_id, {claims, _sig}} -> flavor(claims) == @checkpoint_flavor end)
    |> Enum.flat_map(fn {_id, {claims, _sig}} -> dispatched_refs(claims) end)
    |> MapSet.new()
  end

  defp dispatched_refs(claims) do
    for %{role: "dispatched", target: {:delta, id, _ctx}} <- claims.pointers, do: id
  end

  # ------------------------------------------------------ the agent loop

  # the built-in runtime loop (AC4): a PURE (delta[]) -> delta[] function. On a
  # saturated message.received view it emits ONE message.sent — the
  # deterministic reply `ack <received-id>`, a pointer back to the received
  # claim (caused_by = its id), signed with the agent seed captured here
  # (Ed25519 is deterministic; no IO, no boot, no side effect but the output).
  defp agent_handler(agent_seed) do
    fn deltas ->
      Enum.flat_map(deltas, fn {claims, _sig} -> ack(agent_seed, claims) end)
    end
  end

  defp ack(agent_seed, received_claims) do
    received_id = Delta.id_hex(received_claims)

    case Events.message_sent(
           agent_seed,
           received_claims.timestamp,
           received_id,
           "message:kyber:ack:" <> received_id,
           channel_of(received_claims),
           "ack " <> received_id
         ) do
      {:ok, signed} -> [signed]
      # a malformed received claim yields no reply rather than crashing the
      # loop (reject, never repair) — unreachable for a door-admitted claim
      {:error, _reason} -> []
    end
  end

  # the reply is delivered on the same channel the message arrived on (the "at"
  # pointer of message.received); a claim without one still gets a well-formed
  # reply on a fallback channel rather than crashing the loop.
  defp channel_of(claims) do
    case Enum.find(claims.pointers, &(&1.role == "at")) do
      %{target: {:entity, channel_id, _ctx}} -> channel_id
      _ -> "channel:kyber:unknown"
    end
  end

  # --------------------------------------------------------------- shared

  defp flavor(%{pointers: [%{role: role} | _]}), do: role
  defp flavor(_), do: nil

  # ----------------------------------------------------------- the lock io

  defp write_lock(lock) do
    with :ok <- File.mkdir_p(Path.dirname(lock)),
         :ok <- File.write(lock, System.pid()) do
      :ok
    else
      {:error, reason} -> {:error, {:lock_write_failed, reason}}
    end
  end

  # a dead pid means a stale lock (the daemon was killed) — reclaimable. On
  # Linux (the platform), /proc is authoritative; kill -0 is the fallback.
  # Garbage lock content is treated as dead (reclaim, never brick).
  defp os_alive?(pid_str) do
    case Integer.parse(pid_str) do
      {pid, ""} when pid > 0 ->
        if File.dir?("/proc"), do: File.dir?("/proc/#{pid}"), else: kill_zero?(pid_str)

      _ ->
        false
    end
  end

  defp kill_zero?(pid_str) do
    {_out, code} = System.cmd("kill", ["-0", pid_str], stderr_to_stdout: true)
    code == 0
  rescue
    _ -> false
  end
end
