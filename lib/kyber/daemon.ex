defmodule Kyber.Daemon do
  @moduledoc """
  The operational harness (T10): the long-lived process that watches a kyber
  log, routes new claims to the gather, and shuts down cleanly.

  **Lifecycle (AC1).** `start_link/1` boots the daemon against `--log <path>`
  with `--keyring <dir>`: it acquires the pid-lock at `<log>.daemon` (a file
  carrying the OS pid — a second daemon on the same log is refused with
  `{:error, {:already_running, log}}`; a stale lock whose pid is dead is
  reclaimed, so a killed daemon never bricks re-boot), loads the agent seed
  (the daemon signs its own claims with the keyring's agent key), and
  attaches to the running `Kyber.DurableStore` (starting one itself when the
  app is not booted — the test shape). `GenServer.stop/2` — and SIGTERM in
  the escript, via the link to the app's top supervisor — runs `terminate/2`:
  the lock releases (only ever its OWN lock: the file is removed only when
  its content is still this VM's pid), an owned store is stopped, the ticker
  dies with the process.

  **The ticker** is `Process.send_after/3`-based — there is no
  `Process.sleep/1` anywhere in the stack. Each tick polls the log for lines
  newer than the dispatch cursor and routes their claims to the gather (AC2);
  the cursor persists as `daemon.checkpoint` claims so a re-boot resumes
  exactly where the previous run stopped (AC3).

  **Boot failure discipline.** Every fallible check that can be answered
  before the process exists (lock, keyring) runs in the CALLER inside
  `start_link/1`, so refusals are clean tagged tuples with no process
  spawned and no exit signal delivered; the spawn itself is wrapped in a
  temporary trap so even an init-time failure answers `{:error, reason}`
  without signalling the caller.
  """

  use GenServer

  alias Kyber.{AgentLoop, DeltaSet, DurableStore, Events, Gather, Keys, Log, Store, Wire}

  @default_tick_ms 200
  @lock_suffix ".daemon"
  @lock_attempts 3

  @typedoc "Daemon statistics — the explicit-state-polling surface for tests."
  @type stats :: %{log: Path.t(), cursor: non_neg_integer(), ticks: non_neg_integer()}

  # ------------------------------------------------------------------- API

  @doc """
  Boot the daemon. Required options: `:log` (the store path) and `:keyring`
  (the keyring dir). Optional: `:tick_interval` (ms, default
  #{@default_tick_ms}), `:pulse_only` (roles tuned down to pulse-only — the
  admission knob, AC6).

  Returns `{:error, {:already_running, log}}` when a live daemon holds the
  log's lock, `{:error, :no_agent_seed}` when the keyring has no agent key.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    log = Keyword.fetch!(opts, :log)
    keyring = Keyword.fetch!(opts, :keyring)

    # the lock is released ONLY on paths where THIS call acquired it — a
    # refusal path (already_running) must never touch the live daemon's lock
    case acquire_lock(log) do
      :ok ->
        case Keys.load_agent_seed(keyring) do
          {:ok, agent_seed} ->
            spawn_daemon(Keyword.put(opts, :agent_seed, agent_seed), log)

          {:error, reason} ->
            release_lock(log)
            {:error, reason}
        end

      {:error, _reason} = err ->
        err
    end
  end

  @doc "The daemon's lock file path for `log` (`<log>.daemon`)."
  @spec lock_path(Path.t()) :: Path.t()
  def lock_path(log), do: log <> @lock_suffix

  @doc "Explicit state polling for tests: cursor, tick count, log path."
  @spec stats(GenServer.server()) :: stats()
  def stats(server), do: GenServer.call(server, :stats)

  # the spawn is wrapped in a temporary trap so an init-time {:stop, reason}
  # answers {:error, reason} here WITHOUT an exit signal escaping into a
  # non-trapping caller (the classic start_link init-failure hazard)
  defp spawn_daemon(opts, log) do
    trapping? = Process.flag(:trap_exit, true)

    try do
      case GenServer.start_link(__MODULE__, {opts, log}) do
        {:ok, pid} ->
          {:ok, pid}

        {:error, _reason} = err ->
          flush_exit()
          release_lock(log)
          err
      end
    after
      Process.flag(:trap_exit, trapping?)
    end
  end

  defp flush_exit do
    receive do
      {:EXIT, _pid, _reason} -> :ok
    after
      0 -> :ok
    end
  end

  # ------------------------------------------------------------- callbacks

  @impl true
  def init({opts, log}) do
    Process.flag(:trap_exit, true)
    tick = Keyword.get(opts, :tick_interval, @default_tick_ms)

    # an owned store/gather is LINKED: an init failure exits non-normal and
    # the link reaps the owned child, so a failed boot never leaks processes
    with {:ok, store, store_owned?} <- ensure_store(log),
         {:ok, gather, gather_owned?} <- ensure_gather(opts),
         :ok <- subscribe_agent_loop(gather, opts) do
      link_app_supervisor()
      schedule_tick(tick)
      agent_seed = Keyword.fetch!(opts, :agent_seed)

      {:ok,
       %{
         log: log,
         keyring: Keyword.fetch!(opts, :keyring),
         agent_seed: agent_seed,
         author: Keys.author_for_seed(agent_seed),
         store: store,
         store_owned?: store_owned?,
         gather: gather,
         gather_owned?: gather_owned?,
         supervisor: Process.whereis(Kyber.Supervisor),
         tick_interval: tick,
         now: Keyword.get(opts, :now, fn -> 1.0 * System.system_time(:millisecond) end),
         cursor: recover_cursor(log, Keys.author_for_seed(agent_seed)),
         ticks: 0
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply, %{log: state.log, cursor: state.cursor, ticks: state.ticks}, state}
  end

  @impl true
  def handle_info(:tick, state) do
    schedule_tick(state.tick_interval)
    {state, reports} = dispatch_new_lines(state)
    state = maybe_checkpoint(state, reports)
    {:noreply, %{state | ticks: state.ticks + 1}}
  end

  # the app's top supervisor goes down (SIGTERM -> init:stop -> app shutdown):
  # stop normally so terminate/2 releases the lock before the VM halts
  def handle_info({:EXIT, pid, _reason}, %{supervisor: pid} = state) do
    {:stop, :normal, state}
  end

  # the store we started (linked) died — the daemon cannot run without it
  def handle_info({:EXIT, pid, reason}, %{store: pid, store_owned?: true} = state) do
    {:stop, reason, state}
  end

  # a FOREIGN store (monitored) dying stops the daemon too. A :shutdown
  # reason is the app's own stop sweep (SIGTERM) — the daemon exits NORMAL
  # so the exit does not propagate :shutdown to the linked CLI main (a
  # :normal exit never propagates; the CLI's halt is driven by its monitor)
  def handle_info({:DOWN, _ref, :process, pid, :shutdown}, %{store: pid} = state) do
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, %{store: pid} = state) do
    {:stop, reason, state}
  end

  # the gather we started (linked) died — the daemon cannot dispatch without it
  def handle_info({:EXIT, pid, reason}, %{gather: pid, gather_owned?: true} = state) do
    {:stop, shutdown_to_normal(reason), state}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, %{gather: pid} = state) do
    {:stop, shutdown_to_normal(reason), state}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  # an app-shutdown-driven stop is a NORMAL daemon exit (the CLI main relies
  # on it: a :shutdown reason would propagate down the start_link link and
  # kill the escript's main process before its own halt runs)
  defp shutdown_to_normal(:shutdown), do: :normal
  defp shutdown_to_normal(reason), do: reason

  @impl true
  def terminate(_reason, state) do
    release_lock(state.log)
    stop_owned(%{pid: state.gather, owned?: state.gather_owned?})
    stop_owned(%{pid: state.store, owned?: state.store_owned?})
    :ok
  end

  # --------------------------------------------------------------- the lock

  # O_EXCL create: the exists-check and the create are one operation (no
  # TOCTOU between two racing daemons). A held lock is reclaimed only when
  # its pid is provably dead; anything else refuses.
  defp acquire_lock(log) do
    do_acquire_lock(log, @lock_attempts)
  end

  defp do_acquire_lock(_log, 0), do: {:error, :lock_contended}

  defp do_acquire_lock(log, attempts) do
    path = lock_path(log)

    case File.open(path, [:write, :exclusive, :binary]) do
      {:ok, io} ->
        with :ok <- IO.binwrite(io, System.pid()), :ok <- File.close(io) do
          :ok
        else
          {:error, reason} -> {:error, {:lock_failed, log, reason}}
        end

      {:error, :eexist} ->
        case lock_holder_alive?(path) do
          true ->
            {:error, {:already_running, log}}

          false ->
            File.rm(path)
            do_acquire_lock(log, attempts - 1)
        end

      {:error, reason} ->
        {:error, {:lock_failed, log, reason}}
    end
  end

  # the lock carries the OS pid; a dead pid means a killed daemon and the
  # lock is reclaimed. Garbage content is treated as dead (a corrupt lock
  # must not brick re-boot); an un-runnable `kill -0` is treated as ALIVE —
  # never reclaim what cannot be proven dead.
  defp lock_holder_alive?(path) do
    case File.read(path) do
      {:ok, content} -> os_process_alive?(String.trim(content))
      {:error, _reason} -> false
    end
  end

  defp os_process_alive?(pid_str) do
    case Integer.parse(pid_str) do
      {_pid, ""} ->
        try do
          case System.cmd("kill", ["-0", pid_str], stderr_to_stdout: true) do
            {_out, 0} -> true
            {_out, _code} -> false
          end
        rescue
          _ -> true
        end

      _ ->
        false
    end
  end

  # only ever release OUR lock: the file is removed only when its content is
  # still this VM's pid (a re-booted daemon's fresh lock is never clobbered)
  defp release_lock(log) do
    path = lock_path(log)

    case File.read(path) do
      {:ok, content} ->
        if String.trim(content) == System.pid(), do: File.rm(path)
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  # ------------------------------------------------------ store and gather

  # attach to the running store (the escript boots the app first) or start
  # one on this log when the app is not booted (the test shape). An owned
  # process is linked; a foreign one is monitored.
  defp ensure_store(log) do
    case Process.whereis(DurableStore) do
      nil ->
        case DurableStore.start_link(log) do
          {:ok, pid} -> {:ok, pid, true}
          {:error, reason} -> {:error, {:store_start_failed, reason}}
        end

      pid ->
        Process.monitor(pid)
        {:ok, pid, false}
    end
  end

  defp ensure_gather(opts) do
    case Process.whereis(Gather) do
      nil ->
        case Gather.start_link(pulse_only: Keyword.get(opts, :pulse_only, [])) do
          {:ok, pid} -> {:ok, pid, true}
          {:error, reason} -> {:error, {:gather_start_failed, reason}}
        end

      pid ->
        Process.monitor(pid)
        {:ok, pid, false}
    end
  end

  # the built-in runtime agent loop (AC4): `message.received` in,
  # deterministic `message.sent` out. An already-subscribed shared gather is
  # fine — the loop is the same pure pair for every daemon.
  defp subscribe_agent_loop(gather, opts) do
    {match, handler} =
      AgentLoop.subscription(Keyword.fetch!(opts, :agent_seed),
        now: Keyword.get(opts, :now, fn -> 1.0 * System.system_time(:millisecond) end)
      )

    case Gather.subscribe(gather, AgentLoop.subscription_id(), match, handler) do
      :ok -> :ok
      {:error, {:already_subscribed, _id}} -> :ok
    end
  end

  defp stop_owned(%{owned?: true, pid: pid}) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :normal)
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end

  defp stop_owned(_ref), do: :ok

  # SIGTERM cleanliness in the escript: the daemon is started by the CLI's
  # main process AFTER the app boot, so it is not an application child — but
  # the VM's init:stop stops the app's top supervisor, and the link turns
  # that into a normal stop here, so terminate/2 (the lock release) always
  # runs on SIGTERM. A daemon crash is ignored by the supervisor (a
  # non-child EXIT is no restart trigger).
  defp link_app_supervisor do
    case Process.whereis(Kyber.Supervisor) do
      nil -> :ok
      pid -> Process.link(pid)
    end
  end

  # ----------------------------------------------------- the persisted cursor

  # AC3: the dispatch cursor is a lens with state — persisted as
  # `daemon.checkpoint` claims (state as data), never in-memory-only. Boot
  # replays the log and resumes from the HIGHEST cursor this daemon's own
  # author ever checkpointed (door-verified through the same admit path;
  # a forged checkpoint line fails the door and is skipped). The cursor is
  # a derived reading, never a source of truth: the log is.
  defp recover_cursor(log, author) do
    log
    |> Log.stream()
    |> Enum.reduce(0, fn line, cursor ->
      case checkpoint_cursor(line, author) do
        {:ok, n} -> max(cursor, n)
        :skip -> cursor
      end
    end)
  end

  defp checkpoint_cursor(line, author) do
    with true <- String.trim(line) != "",
         {:ok, wire} when is_map(wire) <- JSON.decode(line),
         {:ok, set} <- Store.admit(wire, DeltaSet.new()),
         {_id, {claims, _sig}} <- Enum.at(set, 0),
         true <- claims.author == author,
         %{role: "checkpoint"} <- List.first(claims.pointers),
         {:number, n} <- cursor_target(claims.pointers) do
      {:ok, trunc(n)}
    else
      _term -> :skip
    end
  end

  defp cursor_target(pointers) do
    Enum.find_value(pointers, :none, fn
      %{role: "cursor", target: {:number, n}} -> {:number, n}
      _pointer -> nil
    end)
  end

  # a tick that admitted at least one NON-checkpoint claim persists the new
  # cursor. Checkpoint claims themselves advance the in-memory cursor but
  # never trigger a checkpoint — the daemon cannot checkpoint itself into an
  # infinite ping-pong, and a re-boot re-skipping old checkpoints re-fires
  # nothing (no handler matches them).
  defp maybe_checkpoint(state, reports) do
    if Enum.any?(reports, &(&1.role != "checkpoint")) do
      write_checkpoint(state)
    else
      state
    end
  end

  defp write_checkpoint(state) do
    daemon_id = "daemon:" <> String.trim_leading(state.author, "ed25519:")

    with {:ok, signed} <-
           Events.daemon_checkpoint(state.agent_seed, state.now.(), daemon_id, state.cursor),
         true <- Process.whereis(DurableStore) != nil do
      signed |> Wire.envelope() |> DurableStore.append()
      :ok
    else
      _term -> :ok
    end

    state
  end

  # -------------------------------------------------------------- the watch

  # AC2: poll the log for lines newer than the dispatch cursor and route
  # their claims to the gather with persist: false — they came FROM the log,
  # so they are already persisted. The cursor advances past EVERY consumed
  # line (admitted, refused, or torn alike: a bad line never becomes good).
  # A claim the daemon itself wrote routes like any claim — the agent loop
  # does not match `message.sent`, so no handler is its own subscriber.
  defp dispatch_new_lines(state) do
    new_lines = state.log |> Log.stream() |> Enum.drop(state.cursor)

    reports =
      Enum.flat_map(new_lines, fn line ->
        case intake_line(state.gather, line) do
          {:ok, report} -> [report]
          :skip -> []
        end
      end)

    {%{state | cursor: state.cursor + length(new_lines)}, reports}
  end

  defp intake_line(gather, line) do
    with true <- String.trim(line) != "",
         {:ok, wire} <- JSON.decode(line),
         {:ok, report} <- Gather.route(gather, wire, persist: false) do
      {:ok, report}
    else
      _term -> :skip
    end
  end

  # --------------------------------------------------------------- the ticker

  defp schedule_tick(interval) do
    Process.send_after(self(), :tick, interval)
  end
end
