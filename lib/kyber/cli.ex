defmodule Kyber.CLI do
  @moduledoc """
  The operator surface (T8): a `kyber` escript over the whole stack. Every
  loop so far shipped a module API; this gives the harness a FACE.

  **Boot ownership (rev 2, the central fix):** `mix.exs` pins `escript:
  [main_module: Kyber.CLI, app: nil]` — `app: nil` is REQUIRED. With the
  default (`app: :kyber`) the escript boots the app on the baked-in dev
  config path BEFORE `main/1` runs, making `--log` dead and store-down
  unreachable. With `app: nil`, `main/1` is the ONLY booter — but the
  pinned `put_env`→`ensure_all_started` order is INSUFFICIENT and is
  corrected here (see `main/1`'s recorded spec contradiction): the actual
  sequence is LOAD `:kyber` (baked config default lands) -> override
  `:log_path` from `--log` -> `Application.ensure_all_started(:kyber)` ->
  `run/1` -> print -> halt.

  `run/1` is PURE dispatch: it parses argv, calls the command's function,
  and formats every tagged error as a clean one-liner — it NEVER calls
  `System.halt/1`, performs IO, or boots the app. It dispatches over
  whatever app state already exists (tests arrange it directly; AC7's
  store-down scenario stops the app first). `main/1` is the ONLY printer,
  halter, and booter; exit codes are pinned `0` (`{:ok, _}`), `1`
  (`{:error, _}`), `2` (`{:error, :usage, _}`).

  **The view guard (rev 2 pin):** `Kyber.Harness.view/0` is the one
  unguarded command API in the stack — a bare `Kyber.DurableStore.set()`.
  The CLI never calls it bare: `view` re-implements the guard + the same
  sort/format Harness.view/0 does internally, wrapped in a whereis check
  and a `catch_exit` (the T4/T5 TOCTOU closure shape) so a store stopping
  between the whereis and the call still answers the clean one-liner,
  never a crash.
  """

  alias Kyber.{Daemon, DurableStore, Federation, Harness, Migration, Peer, Vault}

  @usage """
  kyber [--log <path>] <command> [args]
    view                                   sorted claims, one per line; exit 0
    ingest <source.json> --keyring <dir>   the source map -> Harness.ingest; prints the claim id; exit 0
    daemon --log <path> --keyring <dir> [--tick-ms <n>] [--pulse-only <role>]
                                           run the agent daemon on <path>; prints "daemon running on <path>"; then blocks;
                                           a second daemon on the same log exits 1
    render <vault_dir>                     Vault.render; prints the report; exit 0
    refresh <vault_dir>                    Vault.refresh; prints the report; exit 0
    export                                 Federation.export; prints the wire text verbatim + "\\n"; exit 0
    import <wire.jsonl>                    Federation.import; prints the import report; exit 0
    migrate <legacy.jsonl> --keyring <dir> Migration.migrate; prints the migration report; exit 0
    serve --port <N>                       start a federation peer; prints "listening on <port>"; then blocks
    send <host> <port>                     Federation.export -> the peer; prints its status line; exit 0
    tui [--log <path>] [--socket <path>]   non-booting client: connect to a running daemon's channel
                                           socket, stream the log tail, send operator messages; blocks
    ctl --log <path> <send|status|tail|tick> [msg]   non-interactive control client over the
                                           daemon's channel socket; exit-coded; never boots :kyber
    discord --server <id> --token-env <VAR> [daemon opts]
                                           boot the channel daemon + the Discord gateway (profile
                                           MANDATORY; the token env NAME only, never a value); blocks
    help | (no args)                       this text; exit 0
    <unknown> | help <extra>               this text; exit 2
  """

  # -------------------------------------------------------------------- main

  @doc """
  THE ONLY printer/halter/booter. LOADS `:kyber` (so the baked config
  default lands), THEN overrides `:log_path` from `--log`, THEN boots,
  dispatches through `run/1`, prints the message, and halts with the
  pinned exit code. Never returns.

  **Spec contradiction (rev 2 boot-ownership, RECORDED — see moduledoc):**
  the ticket pins `--log` `put_env` DIRECTLY before `ensure_all_started/1`
  with NO intervening load, claiming `app: nil` alone makes the override
  stick. It does not. With `app: nil` the escript starts `:kyber`
  UNLOADED, so `ensure_all_started/1` triggers `:application.load/1`,
  which re-applies the BUILD-TIME-baked `config/config.exs` default
  (`~/.kyber/store.jsonl`) and CLOBBERS the `put_env` — the exact
  "`--log` is dead / store-down unreachable" failure the fix claims to
  cure, relocated from the boot into the load. The minimal correct
  sequence is `load → put_env → start`: `load_kyber/0` applies the baked
  default first, the override then wins, and the subsequent
  `ensure_all_started/1` (already loaded) cannot re-clobber it. (Verified
  empirically against the built escript, not just the in-VM test path —
  `run/1`'s tests never reach `main/1`, and in `mix test` `:kyber` is
  already loaded, so the pinned sequence LOOKS fine there.)
  """
  @spec main([String.t()]) :: no_return()
  def main(argv) do
    # P5 finding 1: PRE-FLIGHT the argv BEFORE any boot — a usage-error path
    # (a stray/bare --log, no command, help misuse) must NEVER boot the store:
    # the escript's whole data-safety design (app: nil) exists so the real
    # ~/.kyber store is never touched on malformed input. Only a recognized
    # command shape reaches the boot.
    case preflight(argv) do
      {:ok, command_argv, log_path} ->
        boot_and_run(command_argv, log_path)

      # H6: the THIRD preflight outcome — a RECOGNIZED, NON-BOOTING command
      # (kyber tui) runs WITHOUT ever booting :kyber (a booting TUI is a
      # second DurableStore on the live log — the N1 trap)
      {:no_boot, command_argv, _log_path} ->
        command_argv |> run() |> print_and_halt()

      {:usage, exit_code} ->
        IO.puts(@usage)
        System.halt(exit_code)
    end
  end

  # the single source of truth: the SAME parser run/1 uses, plus the command
  # check. [] and ["help"] -> usage, exit 0; ["help" | _] -> usage, exit 2;
  # a stray/bare --log -> usage, exit 2. Usage shapes NEVER boot (a
  # `kyber --log view` must not create ./view). Only a real command boots.
  # The daemon command is FULLY pre-flighted (T10 AC8): every malformed
  # daemon argv is a usage error before any boot — the daemon's --log is a
  # boot flag, so its validation cannot wait for run/1.
  defp preflight(argv) do
    case parse_daemon(argv) do
      {:ok, opts} -> {:ok, argv, opts.log}
      {:error, :usage} -> {:usage, 2}
      :not_daemon -> preflight_command(argv)
    end
  end

  defp preflight_command(argv) do
    # the command class is checked FIRST — `kyber tui --log X` carries its
    # --log AFTER the command (M14) and must never trip reject_stray_log
    case command_class(argv) do
      {:usage, exit_code} ->
        {:usage, exit_code}

      :no_boot ->
        {:no_boot, argv, nil}

      :run ->
        case strip_log_prefix(argv) do
          {:error, :usage} ->
            {:usage, 2}

          {:ok, rest} ->
            {:ok, rest, extract_log_path(argv)}
        end
    end
  end

  # H6: check_command's `_command -> :run` auto-admits ANY new command name
  # into the BOOTING path — the dispatch gets a THIRD outcome: usage |
  # booting | recognized-non-booting, with `tui` in the third class
  defp command_class([]), do: {:usage, 0}
  defp command_class(["help"]), do: {:usage, 0}
  defp command_class(["help" | _rest]), do: {:usage, 2}
  defp command_class(["tui" | _rest]), do: :no_boot
  # T15: `ctl` is a non-booting client like `tui` — its --log rides AFTER the
  # command (M14), so it must NOT trip the stray-log rejection that the :run
  # class applies. Route it to :no_boot so run/1 dispatches it directly.
  defp command_class(["ctl" | _rest]), do: :no_boot
  defp command_class(_command), do: :run

  defp boot_and_run(command_argv, log_path) do
    with :ok <- load_kyber() do
      if log_path, do: Application.put_env(:kyber, :log_path, log_path)

      case Application.ensure_all_started(:kyber) do
        {:ok, _apps} ->
          command_argv |> run() |> print_and_halt()

        {:error, reason} ->
          IO.puts("store failed to start: #{inspect(reason)}")
          System.halt(1)
      end
    else
      {:error, reason} ->
        IO.puts("store failed to start: #{inspect(reason)}")
        System.halt(1)
    end
  end

  # load (not start) FIRST so the baked config default is applied BEFORE the
  # --log override; an already-loaded app (the mix-test path) is a no-op.
  # P5 finding 3: a REAL load error is surfaced (never folded into :ok) —
  # main/1 renders it as the clean "store failed to start" one-liner; only
  # the :already_loaded case is benign.
  defp load_kyber do
    case Application.load(:kyber) do
      :ok -> :ok
      {:error, {:already_loaded, :kyber}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # a bare "--log <path>" PREFIX is the only shape main/1 reads for the boot
  # side effect; anything else (missing value, --log elsewhere) is left for
  # run/1's own parsing to reject as a usage error — single source of truth
  defp extract_log_path(["--log", path | _rest]), do: path
  defp extract_log_path(_argv), do: nil

  # the ONLY serve special case in main/1 (rev 2): print the marker line,
  # then BLOCK in a receive that never matches — the no-sleep rule is
  # absolute, and the peer's live socket keeps the VM alive. Never returns.
  defp print_and_halt({:ok, {:serve, line, _pid}}) do
    IO.puts(line)
    block_forever()
  end

  # daemon (T10): same shape as serve — print the marker, then block; the
  # daemon lives in the supervision tree, and SIGTERM's init:stop unwinds it
  # cleanly (the lock releases; exit 0)
  defp print_and_halt({:ok, {:daemon, line, _pid}}) do
    IO.puts(line)
    block_forever()
  end

  # TUI (T14i H6): print the marker, then block — the TUI process runs
  # concurrently on the group leader; SIGTERM's init:stop unwinds cleanly
  defp print_and_halt({:ok, {:tui, line, _pid}}) do
    IO.puts(line)
    block_forever()
  end

  defp print_and_halt({:ok, message}) do
    print(message)
    System.halt(0)
  end

  defp print_and_halt({:error, :usage, message}) do
    print(message)
    System.halt(2)
  end

  defp print_and_halt({:error, message}) do
    print(message)
    System.halt(1)
  end

  defp block_forever do
    receive do
      :never -> :ok
    end
  end

  # a map ok-message (render/refresh/import/migrate reports) prints as a
  # compact IO.inspect; every other message (view text, a claim id, the
  # wire text, the usage block) is a plain string, printed verbatim +
  # IO.puts's own trailing newline (export's pinned "verbatim + \n")
  defp print(message) when is_map(message), do: IO.inspect(message, limit: :infinity)
  defp print(message) when is_binary(message), do: IO.puts(message)
  # P5 finding 4: the format_error-style defensive-completeness fallback — a
  # future non-binary/non-map ok-message prints cleanly instead of crashing
  # post-success with FunctionClauseError
  defp print(message), do: IO.inspect(message, limit: :infinity)

  # ---------------------------------------------------------------------- run

  @doc """
  PURE dispatch — no halt, no IO, no boot. Parses argv (a `--log <path>`
  global flag BEFORE the command is accepted; `--log` anywhere else is a
  usage error), dispatches to the command, and formats every tagged error
  as a pinned one-liner.
  """
  @spec run([String.t()]) ::
          {:ok, String.t() | map()} | {:error, String.t()} | {:error, :usage, String.t()}
  def run(argv) do
    # daemon first (T10): its `--log` is admitted AFTER the command (AC1's
    # pinned spelling — see the rev 2 grammar note in .adlc/specs/T10-fable.md),
    # so it must not reach the stray---log rejection below. T14i (M14): the
    # TUI's --log is TUI-scoped (after the command) and the discord command
    # carries the daemon opts — both parse before run_command's
    # reject_stray_log.
    case parse_daemon(argv) do
      {:ok, opts} -> cmd_daemon(opts)
      {:error, :usage} -> {:error, :usage, @usage}
      :not_daemon -> run_channel(argv)
    end
  end

  defp run_channel(argv) do
    case parse_tui(argv) do
      {:ok, opts} -> cmd_tui(opts)
      {:error, :usage} -> {:error, :usage, @usage}
      :not_tui -> run_ctl(argv)
    end
  end

  # T15: the `ctl` control client — a non-interactive, exit-coded operator
  # surface over the daemon's channel socket (the SAME JSONL protocol the TUI
  # and Discord gateway speak). `ctl` never boots :kyber.
  defp run_ctl(argv) do
    case parse_ctl(argv) do
      {:ok, opts} -> cmd_ctl(opts)
      {:error, :usage} -> {:error, :usage, @usage}
      :not_ctl -> run_discord(argv)
    end
  end

  defp parse_ctl(["ctl" | rest]), do: ctl_opts(rest, %{log: nil, socket: nil, verb: nil, content: nil})
  defp parse_ctl(_argv), do: :not_ctl

  defp ctl_opts([], %{verb: nil} = _opts), do: {:error, :usage}
  defp ctl_opts([], opts), do: {:ok, opts}
  defp ctl_opts(["--log", path | rest], %{log: nil} = opts), do: ctl_opts(rest, %{opts | log: path})
  defp ctl_opts(["--socket", path | rest], %{socket: nil} = opts), do: ctl_opts(rest, %{opts | socket: path})
  defp ctl_opts(["send", content | rest], %{verb: nil} = opts), do: ctl_opts(rest, %{opts | verb: "send", content: content})
  defp ctl_opts(["status" | rest], %{verb: nil} = opts), do: ctl_opts(rest, %{opts | verb: "status"})
  defp ctl_opts(["tail" | rest], %{verb: nil} = opts), do: ctl_opts(rest, %{opts | verb: "tail"})
  defp ctl_opts(["tick" | rest], %{verb: nil} = opts), do: ctl_opts(rest, %{opts | verb: "tick"})
  defp ctl_opts(_other, _opts), do: {:error, :usage}

  defp cmd_ctl(opts) do
    log_path = opts.log || default_log_path()
    socket_path = opts.socket || log_path <> ".sock"

    case Kyber.CLI.TUI.connect(socket_path) do
      {:ok, socket} ->
        :gen_tcp.close(socket)

        result =
          case opts.verb do
            "send" -> Kyber.CLI.TUI.send_message(socket_path, opts.content)
            "status" -> Kyber.CLI.TUI.status(socket_path)
            "tail" -> Kyber.CLI.TUI.request(socket_path, %{"verb" => "tail"})
            "tick" -> Kyber.CLI.TUI.tick(socket_path)
          end

        case result do
          {:ok, map} -> {:ok, inspect(map)}
          {:error, reason} -> {:error, format_error(reason)}
        end

      {:error, _reason} ->
        {:error, "daemon not running on #{socket_path}"}
    end
  end

  defp run_discord(argv) do
    case parse_discord(argv) do
      {:ok, opts} -> cmd_discord(opts)
      {:error, :usage} -> {:error, :usage, @usage}
      :not_discord -> run_command(argv)
    end
  end

  defp run_command(argv) do
    case strip_log_prefix(argv) do
      # serve returns its marker/error UNCHANGED — run/1 stays pure (no
      # print, no block): main/1's wrapper is the only place that blocks
      {:ok, ["serve", "--port", port_str]} -> serve_start(port: port_str)
      {:ok, ["serve" | _rest]} -> {:error, :usage, @usage}
      {:ok, rest} -> dispatch(rest) |> finalize()
      {:error, :usage} -> {:error, :usage, @usage}
    end
  end

  # strips a LEADING "--log <path>" pair; a "--log" surviving anywhere in
  # the remainder (i.e. anywhere after the command) is a usage error — the
  # pinned rule (rev 2's shape block)
  defp strip_log_prefix(["--log", _path | rest]), do: reject_stray_log(rest)
  defp strip_log_prefix(argv), do: reject_stray_log(argv)

  defp reject_stray_log(argv) do
    if Enum.member?(argv, "--log"), do: {:error, :usage}, else: {:ok, argv}
  end

  defp finalize({:ok, message}), do: {:ok, message}
  defp finalize({:error, :usage, message}), do: {:error, :usage, message}
  defp finalize({:error, reason}), do: {:error, format_error(reason)}

  # ------------------------------------------------------------------ shape

  defp dispatch([]), do: {:ok, @usage}
  defp dispatch(["help"]), do: {:ok, @usage}
  defp dispatch(["help" | _extra]), do: {:error, :usage, @usage}
  defp dispatch(["view"]), do: cmd_view()
  defp dispatch(["ingest", source, "--keyring", dir]), do: cmd_ingest(source, dir)
  defp dispatch(["render", vault_dir]), do: Vault.render(vault_dir)
  defp dispatch(["refresh", vault_dir]), do: Vault.refresh(vault_dir)
  defp dispatch(["export"]), do: Federation.export()
  defp dispatch(["import", wire_path]), do: cmd_import(wire_path)

  defp dispatch(["migrate", legacy_path, "--keyring", dir]),
    do: Migration.migrate(legacy_path, dir)

  defp dispatch(["send", host, port_str]), do: cmd_send(host, port_str)

  defp dispatch(_other), do: {:error, :usage, @usage}

  # ----------------------------------------------------------------- daemon

  # `kyber daemon` (T10): --log is REQUIRED (no implicit default-store
  # daemon — the real ~/.kyber is structurally out of reach) and is accepted
  # either as the T8 global prefix or after the command (AC1's spelling);
  # both at once is ambiguous. --keyring is required; --tick-ms (positive
  # integer) and --pulse-only (repeatable, the AC6 knob) are optional.
  defp parse_daemon(["--log", path, "daemon" | rest]),
    do: daemon_opts(rest, daemon_base(%{log: path}))

  defp parse_daemon(["daemon" | rest]),
    do: daemon_opts(rest, daemon_base(%{}))

  defp parse_daemon(_argv), do: :not_daemon

  # T14i (N4): the channel-capable daemon surface — the base opts map shared
  # by the daemon and the discord command classes
  defp daemon_base(extra) do
    Map.merge(
      %{
        log: nil,
        keyring: nil,
        tick_ms: nil,
        pulse_only: [],
        loop: nil,
        profile: nil,
        operator_seed_env: nil,
        channel_socket: nil,
        # T15: model/provider identity for the engine (default k3, overridden
        # for isolated sibling agents like Wisp). api_key is an ENV NAME
        # (never a value on argv — ps-visible), resolved at boot like
        # --operator-seed-env.
        model: nil,
        base_url: nil,
        api_key_env: nil,
        system_prompt: nil,
        peer_port: nil,
        oracle_seed: :absent
      },
      extra
    )
  end

  # L8: `--channel-socket` WITHOUT `--loop reactor` is a usage error, exit 2
  # (under :ack sends persist but get the T10 ack-loop answer — the refusal
  # is evidence-backed)
  defp daemon_opts([], %{log: log, keyring: keyring} = opts)
       when is_binary(log) and is_binary(keyring) do
    if opts.channel_socket != nil and opts.loop != :reactor do
      {:error, :usage}
    else
      {:ok, opts}
    end
  end

  defp daemon_opts([], _incomplete), do: {:error, :usage}

  defp daemon_opts(["--log", path | rest], %{log: nil} = opts),
    do: daemon_opts(rest, %{opts | log: path})

  defp daemon_opts(["--keyring", dir | rest], %{keyring: nil} = opts),
    do: daemon_opts(rest, %{opts | keyring: dir})

  defp daemon_opts(["--tick-ms", text | rest], %{tick_ms: nil} = opts) do
    case Integer.parse(text) do
      {ms, ""} when ms > 0 -> daemon_opts(rest, %{opts | tick_ms: ms})
      _ -> {:error, :usage}
    end
  end

  defp daemon_opts(["--pulse-only", role | rest], opts) when role != "",
    do: daemon_opts(rest, %{opts | pulse_only: opts.pulse_only ++ [role]})

  defp daemon_opts(["--loop", "reactor" | rest], %{loop: nil} = opts),
    do: daemon_opts(rest, %{opts | loop: :reactor})

  defp daemon_opts(["--profile", name | rest], %{profile: nil} = opts) when name != "",
    do: daemon_opts(rest, %{opts | profile: name})

  # N4/M5: --operator-seed-env takes the env NAME (never a value); the VALUE
  # is 64-hex-validated at the CLI (usage exit 2) — a garbage env value
  # raises ArgumentError at boot otherwise
  defp daemon_opts(["--operator-seed-env", var | rest], %{operator_seed_env: nil} = opts)
       when var != "",
       do: daemon_opts(rest, %{opts | operator_seed_env: var})

  # --channel-socket [<path>]: a bare flag defaults to <log>.sock (the
  # discovery file IS the socket); a path rides explicitly. A following
  # "--"-prefixed token is the next flag, never a path.
  defp daemon_opts(["--channel-socket" | rest], %{channel_socket: nil} = opts) do
    case rest do
      [path | rest2] when is_binary(path) ->
        if String.starts_with?(path, "--") do
          daemon_opts(rest, %{opts | channel_socket: :default})
        else
          daemon_opts(rest2, %{opts | channel_socket: path})
        end

      _other ->
        daemon_opts(rest, %{opts | channel_socket: :default})
    end
  end

  # T15: model/provider identity flags for an isolated sibling agent.
  defp daemon_opts(["--model", m | rest], %{model: nil} = opts) when m != "",
    do: daemon_opts(rest, %{opts | model: m})
  defp daemon_opts(["--base-url", u | rest], %{base_url: nil} = opts) when u != "",
    do: daemon_opts(rest, %{opts | base_url: u})
  # api_key is an ENV NAME (never a value on argv — ps-visible); resolved at boot
  defp daemon_opts(["--api-key-env", var | rest], %{api_key_env: nil} = opts) when var != "",
    do: daemon_opts(rest, %{opts | api_key_env: var})
  defp daemon_opts(["--system-prompt", p | rest], %{system_prompt: nil} = opts) when p != "",
    do: daemon_opts(rest, %{opts | system_prompt: p})
  defp daemon_opts(["--peer-port", p | rest], %{peer_port: nil} = opts) do
    case Integer.parse(p) do
      {port, ""} when port > 0 and port < 65536 -> daemon_opts(rest, %{opts | peer_port: port})
      _ -> {:error, :usage}
    end
  end

  # T15: oracle seed presence — :present makes the reactor's own signing
  # seed available so the prompt gate (oracle_gate) allows dispatch; :absent
  # (default) keeps a bare daemon refuse-only.
  defp daemon_opts(["--oracle-seed", "present" | rest], opts),
    do: daemon_opts(rest, %{opts | oracle_seed: :present})
  defp daemon_opts(["--oracle-seed", "absent" | rest], opts),
    do: daemon_opts(rest, %{opts | oracle_seed: :absent})

  defp daemon_opts(_other, _opts), do: {:error, :usage}

  # boot the daemon into the supervision tree and hand main/1 the blocking
  # marker; the printed path comes from the daemon's own status (the store it
  # actually watches), not the argv
  defp cmd_daemon(opts) do
    case resolve_operator_seed(opts) do
      {:ok, operator_seed} ->
        # T15: resolve the model identity (env NAME -> value, never on argv)
        api_key = resolve_env_value(opts.api_key_env)
        boot_opts =
          [
            keyring_dir: opts.keyring,
            pulse_only: opts.pulse_only,
            narrate: true,
            loop: opts.loop || :ack,
            profile: opts.profile,
            operator_seed: operator_seed,
            channel_socket: opts.channel_socket,
            api_key: api_key,
            base_url: opts.base_url,
            model: opts.model,
            system_prompt: opts.system_prompt,
            peer_port: opts.peer_port,
            oracle_seed: opts.oracle_seed || :absent
          ] ++
            if(opts.tick_ms, do: [tick_ms: opts.tick_ms], else: [])

        case Daemon.boot(boot_opts) do
          {:ok, pid} ->
            %{log_path: log_path} = Daemon.status()
            {:ok, {:daemon, "daemon running on #{log_path}", pid}}

          {:error, reason} ->
            {:error, format_error(reason)}
        end

      {:error, :usage} ->
        {:error, :usage, @usage}

      {:error, reason} ->
        {:error, format_error(reason)}
    end
  end

  # M5: --operator-seed-env's VALUE is 64-hex-validated at the CLI (usage
  # exit 2); an unset env is a nil seed (sends refuse — the no_operator_seed
  # gate); an absent env NAME is nil too. The value NEVER rides argv.
  defp resolve_operator_seed(%{operator_seed_env: nil}), do: {:ok, nil}

  defp resolve_operator_seed(%{operator_seed_env: var}) do
    case System.get_env(var) do
      nil ->
        {:ok, nil}

      value ->
        case Base.decode16(String.trim(value), case: :mixed) do
          {:ok, <<_::binary-32>>} -> {:ok, String.downcase(String.trim(value))}
          _garbage -> {:error, :usage}
        end
    end
  end

  # T15: generic ENV-NAME -> VALUE resolver for the model api key. An unset or
  # empty env yields nil (the handler refuses a missing key); the value NEVER
  # rides argv. Mirrors resolve_operator_seed's ps-safety posture.
  defp resolve_env_value(nil), do: nil
  defp resolve_env_value(var) when is_binary(var), do: System.get_env(var)

  # -------------------------------------------------------------- T14i

  # M14: the TUI argv shape is pinned — a TUI-scoped --log/--socket opt
  # AFTER the command (the global-prefix form is stripped before dispatch);
  # the no-flag default replicates application.ex's default_log_path/0
  # (including the HOME-unset raise)
  defp parse_tui(["tui" | rest]), do: tui_opts(rest, %{log: nil, socket: nil})
  defp parse_tui(_argv), do: :not_tui

  defp tui_opts([], opts), do: {:ok, opts}
  defp tui_opts(["--log", path | rest], %{log: nil} = opts), do: tui_opts(rest, %{opts | log: path})
  defp tui_opts(["--socket", path | rest], %{socket: nil} = opts), do: tui_opts(rest, %{opts | socket: path})
  defp tui_opts(_other, _opts), do: {:error, :usage}

  # H6: the NON-booting TUI command. The socket probe happens here (before
  # any marker): a running daemon yields the blocking marker tuple; a
  # missing daemon is the clean one-liner, exit 1. Never boots :kyber —
  # the escript-level witness asserts `kyber tui` boots NOTHING.
  defp cmd_tui(opts) do
    log_path = opts.log || default_log_path()
    socket_path = opts.socket || log_path <> ".sock"

    case Kyber.CLI.TUI.connect(socket_path) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        pid = spawn(fn -> Kyber.CLI.TUI.interactive(log_path, socket_path) end)
        {:ok, {:tui, "tui connected to #{log_path}", pid}}

      {:error, _reason} ->
        {:error, "daemon not running on #{socket_path}"}
    end
  end

  defp default_log_path do
    case System.user_home() do
      "" ->
        raise "kyber: cannot resolve the default log_path — HOME is unset " <>
                "(System.user_home() is empty). Pass --log explicitly."

      home ->
        Path.join(home, ".kyber/store.jsonl")
    end
  end

  # H9: `kyber discord …` — the gateway boot surface. argv carries
  # --server <id> and --token-env <VAR> (the env NAME, never a value — a
  # `--token <value>` on argv is a usage error, exit 2, ps-visible), plus
  # the daemon opts (--log/--keyring/--profile/--operator-seed-env/
  # --channel-socket/--tick-ms). Profile is MANDATORY; the gateway URL
  # defaults to the pinned Discord gateway; intents 33280.
  defp parse_discord(["discord" | rest]) do
    case extract_gateway_flags(rest, %{server: nil, token_env: nil}) do
      {:ok, gateway, rest2} ->
        case daemon_opts(rest2, daemon_base(%{})) do
          {:ok, opts} when is_binary(gateway.server) and is_binary(gateway.token_env) ->
            {:ok, Map.merge(opts, gateway)}

          {:ok, _opts} ->
            {:error, :usage}

          {:error, :usage} ->
            {:error, :usage}
        end

      {:error, :usage} ->
        {:error, :usage}
    end
  end

  defp parse_discord(_argv), do: :not_discord

  defp extract_gateway_flags([], gateway), do: {:ok, gateway, []}

  defp extract_gateway_flags(["--server", id | rest], %{server: nil} = gateway) when id != "",
    do: extract_gateway_flags(rest, %{gateway | server: id})

  defp extract_gateway_flags(["--token-env", var | rest], %{token_env: nil} = gateway) when var != "",
    do: extract_gateway_flags(rest, %{gateway | token_env: var})

  # token hygiene: a token VALUE on argv is a usage error, exit 2 (ps-visible)
  defp extract_gateway_flags(["--token" | _rest], _gateway), do: {:error, :usage}

  # the first non-gateway flag ends the gateway segment — the rest are daemon opts
  defp extract_gateway_flags([flag | rest], gateway) when is_binary(flag) do
    if String.starts_with?(flag, "--") do
      {:ok, gateway, [flag | rest]}
    else
      {:error, :usage}
    end
  end

  defp cmd_discord(opts) do
    with :ok <- require_gateway_profile(opts),
         {:ok, operator_seed} <- resolve_operator_seed(opts),
         {:ok, token} <- resolve_discord_token(opts) do
      boot_opts =
        [
          keyring_dir: opts.keyring,
          pulse_only: opts.pulse_only,
          narrate: true,
          loop: :reactor,
          oracle_seed: :present,
          profile: opts.profile,
          operator_seed: operator_seed,
          channel_socket: opts.channel_socket || :default,
          gateway: [
            server_id: opts.server,
            # M12: the token rides as a closure — outside inspectable state
            token: fn -> token end,
            intents: 33_280,
            url: "wss://gateway.discord.gg/?v=10&encoding=json"
          ]
        ] ++
          if(opts.tick_ms, do: [tick_ms: opts.tick_ms], else: [])

      case Daemon.boot(boot_opts) do
        {:ok, pid} ->
          %{log_path: log_path} = Daemon.status()
          {:ok, {:daemon, "discord gateway running on #{log_path}", pid}}

        {:error, reason} ->
          {:error, format_error(reason)}
      end
    else
      {:error, :usage} -> {:error, :usage, @usage}
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  # H9: the PROFILE-MANDATORY refusal — a profile-less gateway boot is
  # {:error, {:unknown_profile, nil}}; a profile-without-seed boot is the
  # H7 refusal at Daemon.boot (the same reason)
  defp require_gateway_profile(%{profile: nil}), do: {:error, {:unknown_profile, nil}}
  defp require_gateway_profile(_opts), do: :ok

  # fail-closed token resolution: absent env => boot error, no default, no
  # retry, no file fallback (D2)
  defp resolve_discord_token(%{token_env: var}) do
    case System.get_env(var) do
      nil -> {:error, {:discord_token_missing, var}}
      token when is_binary(token) and token != "" -> {:ok, token}
      _empty -> {:error, {:discord_token_missing, var}}
    end
  end

  # ------------------------------------------------------------------ serve

  @doc """
  Start a federation peer and return the MARKER (rev 2): `{:ok, {:serve,
  line, pid}}` where `line` is `"listening on <actual-bound-port>"` (port 0
  binds an ephemeral port; the printed line carries the real number). A
  non-integer/out-of-range `--port` → a usage error; a listen failure (e.g.
  the port is in use) → the `"listen failed: <reason>"` one-liner. This
  starts a live socket but does NOT print or block — `main/1` does that.
  """
  @spec serve_start(port: String.t()) ::
          {:ok, {:serve, String.t(), pid()}}
          | {:error, String.t()}
          | {:error, :usage, String.t()}
  def serve_start(opts) do
    case parse_port(Keyword.fetch!(opts, :port)) do
      {:ok, port} ->
        case Peer.start_link(port: port) do
          {:ok, pid} -> {:ok, {:serve, "listening on #{Peer.port(pid)}", pid}}
          {:error, reason} -> {:error, "listen failed: #{inspect(reason)}"}
        end

      :error ->
        {:error, :usage, @usage}
    end
  end

  # ------------------------------------------------------------------- send

  # export the running store, ship it to the peer, print its status verbatim;
  # a store-down/export failure surfaces the store's own tagged tuple (T8
  # discipline), a transport failure the "peer unreachable" one-liner, and a
  # non-integer port a usage error (exit 2)
  defp cmd_send(host, port_str) do
    case parse_port(port_str) do
      {:ok, port} ->
        with {:ok, text} <- Federation.export() do
          case Peer.send_wire(host, port, text) do
            {:ok, status} -> {:ok, status}
            # P5 finding 4: the error taxonomy is NOT collapsed — a connect
            # failure is 'peer unreachable' (the host is down), but a live
            # peer that answered late or closed without replying gets its own
            # diagnostic (the operator must not hunt for a down host while
            # the peer is up and may have imported the claims)
            {:error, :timeout} -> {:error, {:peer_timeout, host, port}}
            {:error, :closed} -> {:error, {:peer_closed, host, port}}
            {:error, _reason} -> {:error, {:peer_unreachable, host, port}}
          end
        end

      :error ->
        {:error, :usage, @usage}
    end
  end

  defp parse_port(str) do
    case Integer.parse(str) do
      {n, ""} when n >= 0 and n <= 65_535 -> {:ok, n}
      _ -> :error
    end
  end

  # ----------------------------------------------------------------- view

  # the guard Harness.view/0 does NOT have: whereis first, then the SAME
  # TOCTOU catch_exit closure Kyber.Harness/Kyber.Vault use around their own
  # DurableStore calls, so a store dying in the window still answers the
  # clean one-liner instead of a crash
  defp cmd_view do
    case guarded_set() do
      {:ok, set} -> {:ok, render_view(set)}
      {:error, _reason} = err -> err
    end
  end

  defp guarded_set do
    if Process.whereis(DurableStore) do
      try do
        {:ok, DurableStore.set()}
      catch
        :exit, {:noproc, _} -> {:error, :store_not_running}
        :exit, reason -> {:error, {:store_exit, reason}}
      end
    else
      {:error, :store_not_running}
    end
  end

  defp render_view(set) do
    set
    |> Enum.sort_by(fn {id_hex, _element} -> id_hex end)
    |> Enum.map(fn {id_hex, {claims, _sig}} -> view_line(id_hex, claims) end)
    |> Enum.join("\n")
  end

  # PINNED BYTE-EXACT (rev 2): "<id_hex> <first-pointer-role>
  # <first-8-hex-after-ed25519:> <ts via float_to_binary decimals: 0>"
  defp view_line(id_hex, claims) do
    role = claims.pointers |> List.first() |> Map.fetch!(:role)
    author8 = author_hex8(claims.author)
    ts_text = :erlang.float_to_binary(claims.timestamp, decimals: 0)
    Enum.join([id_hex, role, author8, ts_text], " ")
  end

  defp author_hex8("ed25519:" <> hex), do: String.slice(hex, 0, 8)
  defp author_hex8(other), do: String.slice(other, 0, 8)

  # ---------------------------------------------------------------- ingest

  defp cmd_ingest(source_path, keyring_dir) do
    with {:ok, content} <- read_file(source_path),
         {:ok, term} <- decode_source(content) do
      case Harness.ingest(term, keyring_dir) do
        {:ok, id} -> {:ok, id}
        {:error, :no_human_seed} -> {:error, {:no_human_seed, keyring_dir}}
        {:error, _reason} = err -> err
      end
    end
  end

  defp decode_source(content) do
    case JSON.decode(content) do
      {:ok, term} when is_map(term) -> {:ok, term}
      {:ok, _term} -> {:error, :malformed_source}
      {:error, _reason} -> {:error, :malformed_source}
    end
  end

  # ----------------------------------------------------------------- import

  defp cmd_import(wire_path) do
    with {:ok, content} <- read_file(wire_path) do
      Federation.import(content)
    end
  end

  # -------------------------------------------------------------------- file

  # NON-bang: a missing/unreadable file is a tagged tuple, the pinned
  # "no such file: <path>" one-liner — never a crash
  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, _reason} -> {:error, {:no_such_file, path}}
    end
  end

  # ------------------------------------------------------------------ errors

  # every tag any command API can return, pinned to a clean one-liner; a
  # tag outside the pinned set still never crashes — it falls to the
  # `inspect` fallback (defensive completeness, the codebase's own idiom
  # for "unreachable today, kept so a future contract drift cannot surface
  # a crash" — see Kyber.Federation's dead branches).
  defp format_error(:store_not_running), do: "store not running"
  defp format_error(:no_agent_seed), do: "no agent seed"
  defp format_error({:no_human_seed, path}), do: "no human seed: #{path}"
  defp format_error({:keyring_dir_missing, path}), do: "keyring dir missing: #{path}"
  defp format_error({:no_legacy_log, path}), do: "no legacy log: #{path}"
  defp format_error({:no_such_file, path}), do: "no such file: #{path}"
  defp format_error(:malformed_source), do: "malformed source"
  # Federation.import/1's non-binary catch-all — structurally unreachable
  # via cmd_import (File.read/1 always yields a binary on :ok), kept for
  # total coverage should Federation's contract ever route :malformed_text
  # through this call.
  defp format_error(:malformed_text), do: "malformed wire"
  defp format_error({:already_running, path}), do: "daemon already running on #{path}"
  defp format_error({:peer_unreachable, host, port}), do: "peer unreachable: #{host} #{port}"
  defp format_error({:peer_timeout, host, port}), do: "peer timeout: #{host} #{port}"
  defp format_error({:peer_closed, host, port}), do: "peer closed: #{host} #{port}"
  # T14i: the profile/gateway one-liners — the H9 profile-mandatory refusal
  # and the H7 profile-without-seed refusal share the {:unknown_profile, _}
  # family; the fail-closed token boot error
  defp format_error({:unknown_profile, nil}), do: "gateway requires a profile"
  defp format_error({:unknown_profile, name}), do: "unknown profile: #{name}"
  defp format_error({:discord_token_missing, var}), do: "no discord token: #{var}"
  defp format_error(other), do: "error: #{inspect(other)}"
end
