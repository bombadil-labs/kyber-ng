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

  alias Kyber.{Daemon, DeltaSet, DurableStore, Federation, Harness, Migration, Peer, Vault}
  alias Kyber.{Keys, Log, Schema, Store, Wire}
  alias Kyber.Agent.{Config, Secrets}
  alias Kyber.Agent.Events, as: AgentEvents

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
    ctl --log <path> set-config <name> <json>   append an operator-attested AgentSet delta over the
                                           served channel (daemon-signed; door-validated)
    discord --server <id> --token-env <VAR> [daemon opts]
                                           boot the channel daemon + the Discord gateway (profile
                                           MANDATORY; the token env NAME only, never a value); blocks
    agent new <name> --soul <text> [--model ..] [--base-url ..] [--api-key-env NAME]
              [--operator-seed-env NAME] [--registry <dir>] [--force]
                                           create an agent: store + genesis (deepseek fallback) delta +
                                           the operator's seed delta; writes the registry pointer; never boots
    agent list | show <name>               fold the AgentSet stream and print it (no boot)
    agent set <name> --<field> <value> ... | set-soul <name> <text> | unset <name> <field>
                                           append an operator-attested AgentSet delta (only changed
                                           fields; re-asserting the current value is a no-op).
                                           --api-key (bare) reads the key from STDIN and stores it
                                           encrypted; a key VALUE on argv is refused (ps-visible).
                                           Write verbs (set/retract/rekey/tombstone) REFUSE while a
                                           daemon holds the store lock — route the change through
                                           `kyber ctl set-config` instead; offline appends directly
    agent retract <name> <delta-id>        negate a delta; the fold steps back per field
    agent rekey <name> --new-seed-env NAME move operator authority to the new seed: the old-signed
                                           handoff + a new-signed config snapshot land in the store
                                           FIRST, then the pointer chain is REPLACED (old seed revoked).
                                           Crash-safe: interrupted before the pointer write, the old
                                           chain stays live — re-run with --operator-seed-env <OLD>
                                           --new-seed-env <NEW> to finish
    agent tombstone <name> <delta-id> --field <f> [--rotated <note>]
                                           the leaked-secret runbook: retract the offending delta,
                                           append a SecretTombstone claim recording the exposure,
                                           then ROTATE the credential itself (the store is append-only
                                           and federates — a leaked value must be considered burned)
    daemon --agent <name> [--registry <dir>] [daemon opts]
                                           boot from the registry pointer: store -> fold -> boot opts;
                                           CLI flags override the fold (overrides never append deltas)
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

      # T17: a recognized boot command whose pre-boot resolution failed (a
      # missing --agent pointer) — the clean one-liner, exit 1, NO boot
      {:fail, message} ->
        IO.puts(message)
        System.halt(1)

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
      {:ok, opts} ->
        # T17: `daemon --agent <name>` boots on the POINTER's log path —
        # resolved HERE, pre-boot, so the baked ~/.kyber default is never
        # opened when the pointer is missing or malformed.
        case daemon_boot_log(opts) do
          {:ok, log} -> {:ok, argv, log}
          {:error, reason} -> {:fail, format_error(reason)}
        end

      {:error, :usage} ->
        {:usage, 2}

      :not_daemon ->
        preflight_command(argv)
    end
  end

  defp daemon_boot_log(%{agent: nil} = opts), do: {:ok, opts.log}

  defp daemon_boot_log(opts) do
    with {:ok, pointer} <- agent_read_pointer(opts), do: {:ok, pointer.log_path}
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
  # T17: the agent verbs open the store file directly (Log + Store.admit) —
  # booting :kyber would put a second DurableStore on a possibly-live log
  # (the N1 trap) AND touch the real ~/.kyber on the baked config path.
  defp command_class(["agent" | _rest]), do: :no_boot
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
      :not_ctl -> run_agent(argv)
    end
  end

  # T17: the `agent` verbs — the operator's no-boot mutation surface over an
  # agent's AgentSet store (see the "agent" section below)
  defp run_agent(argv) do
    case parse_agent(argv) do
      {:ok, opts} -> cmd_agent(opts)
      {:error, :usage} -> {:error, :usage, @usage}
      {:error, reason} -> {:error, format_error(reason)}
      :not_agent -> run_discord(argv)
    end
  end

  defp parse_ctl(["ctl" | rest]),
    do: ctl_opts(rest, %{log: nil, socket: nil, verb: nil, content: nil})

  defp parse_ctl(_argv), do: :not_ctl

  defp ctl_opts([], %{verb: nil} = _opts), do: {:error, :usage}
  defp ctl_opts([], opts), do: {:ok, opts}

  defp ctl_opts(["--log", path | rest], %{log: nil} = opts),
    do: ctl_opts(rest, %{opts | log: path})

  defp ctl_opts(["--socket", path | rest], %{socket: nil} = opts),
    do: ctl_opts(rest, %{opts | socket: path})

  defp ctl_opts(["send", content | rest], %{verb: nil} = opts),
    do: ctl_opts(rest, %{opts | verb: "send", content: content})

  defp ctl_opts(["status" | rest], %{verb: nil} = opts),
    do: ctl_opts(rest, %{opts | verb: "status"})

  defp ctl_opts(["tail" | rest], %{verb: nil} = opts), do: ctl_opts(rest, %{opts | verb: "tail"})
  defp ctl_opts(["tick" | rest], %{verb: nil} = opts), do: ctl_opts(rest, %{opts | verb: "tick"})

  # T17 AC9: `set-config <name> <json-object>` — the fields JSON is decoded
  # at parse time so malformed argv is a usage error, never a socket round
  # trip; the daemon-side door (AC17) still validates every field
  defp ctl_opts(["set-config", name, json | rest], %{verb: nil} = opts) do
    case JSON.decode(json) do
      {:ok, fields} when is_map(fields) ->
        ctl_opts(rest, %{opts | verb: "set-config", content: {name, fields}})

      _not_an_object ->
        {:error, :usage}
    end
  end

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
            "set-config" -> ctl_set_config(socket_path, opts.content)
          end

        case result do
          {:ok, map} ->
            # A daemon response carrying an "error" key is a failed request,
            # not success — surface it as an error so the CLI exits non-zero
            # (AC3: ctl exits 0/1). Otherwise the calling automation cannot
            # tell a rejected command from a successful one.
            if Map.get(map, "error") do
              {:error, format_error(map["error"])}
            else
              {:ok, inspect(map)}
            end

          {:error, reason} ->
            {:error, format_error(reason)}
        end

      {:error, _reason} ->
        {:error, "daemon not running on #{socket_path}"}
    end
  end

  defp ctl_set_config(socket_path, {name, fields}) do
    Kyber.CLI.TUI.request(socket_path, %{
      "verb" => "set-config",
      "name" => name,
      "fields" => fields
    })
  end

  # ------------------------------------------------------------------ agent

  # T17: the genesis default layer — always the FIRST delta `agent new`
  # appends, so the deepseek fallback is already in the stream (D7: a
  # default is just an earlier delta; later deltas override; retraction
  # steps back onto it).
  @agent_genesis %{
    base_url: "https://api.deepseek.com/v1",
    model: "deepseek-v4-flash",
    api_key_env: "DEEPSEEK_API_KEY",
    oracle_seed: "absent",
    loop: "reactor",
    channel_socket: "default",
    self_config: "false"
  }

  # field flags -> the AgentSet field vocabulary (door-validated before any
  # delta is built)
  @agent_flag_fields %{
    "--soul" => :soul,
    "--model" => :model,
    "--base-url" => :base_url,
    "--api-key-env" => :api_key_env,
    "--system-prompt" => :system_prompt,
    "--profile" => :profile,
    "--loop" => :loop,
    "--oracle-seed" => :oracle_seed,
    "--channel-socket" => :channel_socket,
    "--self-config" => :self_config
  }

  defp parse_agent(["agent" | rest]), do: agent_verb(rest)
  defp parse_agent(_argv), do: :not_agent

  defp agent_verb(["new", name | rest]), do: agent_named(name, rest, :new)
  defp agent_verb(["list" | rest]), do: agent_opts(rest, agent_base(:list, nil))
  defp agent_verb(["show", name | rest]), do: agent_named(name, rest, :show)
  defp agent_verb(["set", name | rest]), do: agent_named(name, rest, :set)

  defp agent_verb(["set-soul", name, text | rest]) do
    with {:ok, opts} <- agent_named(name, rest, :set) do
      if agent_flag?(text),
        do: {:error, :usage},
        else: {:ok, %{opts | fields: Map.put(opts.fields, :soul, text)}}
    end
  end

  defp agent_verb(["unset", name, field | rest]) do
    with {:ok, opts} <- agent_named(name, rest, :set) do
      if agent_flag?(field), do: {:error, :usage}, else: {:ok, %{opts | unset: [field]}}
    end
  end

  defp agent_verb(["retract", name, target | rest]) do
    with {:ok, opts} <- agent_named(name, rest, :retract) do
      if agent_flag?(target), do: {:error, :usage}, else: {:ok, %{opts | target: target}}
    end
  end

  defp agent_verb(["rekey", name | rest]), do: agent_named(name, rest, :rekey)

  defp agent_verb(["tombstone", name, target | rest]) do
    with {:ok, opts} <- agent_named(name, rest, :tombstone) do
      if agent_flag?(target), do: {:error, :usage}, else: {:ok, %{opts | target: target}}
    end
  end

  defp agent_verb(_other), do: {:error, :usage}

  defp agent_named("--" <> _flag, _rest, _verb), do: {:error, :usage}

  defp agent_named(name, rest, verb) do
    with :ok <- agent_valid_name(name) do
      agent_opts(rest, agent_base(verb, name))
    end
  end

  # P5 HIGH-2: the agent NAME becomes a filesystem path component (and
  # `new --force` runs rm_rf on it) — a single plain component only, never
  # a traversal, an absolute path, or a separator
  @agent_name_shape ~r/^[a-z0-9][a-z0-9_-]*$/
  defp agent_valid_name(name) do
    if is_binary(name) and Regex.match?(@agent_name_shape, name),
      do: :ok,
      else: {:error, {:invalid_agent_name, name}}
  end

  defp agent_flag?(token), do: String.starts_with?(token, "--")

  defp agent_base(verb, name) do
    %{
      verb: verb,
      name: name,
      registry: nil,
      operator_seed_env: nil,
      force: false,
      fields: %{},
      unset: [],
      api_key_stdin: false,
      new_seed_env: nil,
      target: nil,
      field: nil,
      rotated: nil
    }
  end

  defp agent_opts([], opts), do: {:ok, opts}

  defp agent_opts(["--registry", dir | rest], %{registry: nil} = opts) when dir != "",
    do: agent_opts(rest, %{opts | registry: dir})

  # the signing env NAME — and, on a write, ALSO the recorded
  # `operator_seed_env` field (so later verbs and the daemon find the seed);
  # the door refuses a 64-hex VALUE here (AC21)
  defp agent_opts(["--operator-seed-env", var | rest], %{operator_seed_env: nil} = opts)
       when var != "",
       do:
         agent_opts(rest, %{
           opts
           | operator_seed_env: var,
             fields: Map.put(opts.fields, :operator_seed_env, var)
         })

  defp agent_opts(["--force" | rest], opts), do: agent_opts(rest, %{opts | force: true})

  defp agent_opts(["--new-seed-env", var | rest], %{new_seed_env: nil} = opts) when var != "",
    do: agent_opts(rest, %{opts | new_seed_env: var})

  defp agent_opts(["--field", field | rest], %{field: nil} = opts) when field != "",
    do: agent_opts(rest, %{opts | field: field})

  defp agent_opts(["--rotated", note | rest], %{rotated: nil} = opts) when note != "",
    do: agent_opts(rest, %{opts | rotated: note})

  defp agent_opts(["--unset", field | rest], opts) when field != "",
    do: agent_opts(rest, %{opts | unset: opts.unset ++ [field]})

  # --api-key: BARE reads the value from STDIN and stores it encrypted
  # (AC20); a VALUE on argv is refused outright — argv is ps-visible (AC17)
  defp agent_opts(["--api-key" | rest], opts) do
    case rest do
      [<<"--", _::binary>> | _more] -> agent_opts(rest, %{opts | api_key_stdin: true})
      [] -> agent_opts([], %{opts | api_key_stdin: true})
      [_value | _more] -> {:error, :plaintext_key_on_argv}
    end
  end

  defp agent_opts([flag, value | rest], opts)
       when is_map_key(@agent_flag_fields, flag) and value != "" do
    field = Map.fetch!(@agent_flag_fields, flag)

    if Map.has_key?(opts.fields, field),
      do: {:error, :usage},
      else: agent_opts(rest, %{opts | fields: Map.put(opts.fields, field, value)})
  end

  defp agent_opts(_other, _opts), do: {:error, :usage}

  defp cmd_agent(opts), do: opts |> agent_dispatch() |> finalize()

  defp agent_dispatch(%{verb: :new} = opts), do: agent_new(opts)
  defp agent_dispatch(%{verb: :list} = opts), do: agent_list(opts)
  defp agent_dispatch(%{verb: :show} = opts), do: agent_show(opts)
  defp agent_dispatch(%{verb: :set} = opts), do: agent_set_cmd(opts)
  defp agent_dispatch(%{verb: :retract} = opts), do: agent_retract_cmd(opts)
  defp agent_dispatch(%{verb: :rekey} = opts), do: agent_rekey(opts)
  defp agent_dispatch(%{verb: :tombstone} = opts), do: agent_tombstone(opts)

  # ---- new (AC1/AC14)

  defp agent_new(opts) do
    registry = agent_registry(opts)
    paths = agent_paths(registry, opts.name)

    case agent_new_admission(registry, paths, opts) do
      {:ok, release} ->
        try do
          with {:ok, seed, seed_var} <- agent_signing_seed(opts, nil),
               {:ok, fields} <- agent_stdin_key(opts, opts.fields, seed),
               fields = Map.put_new(fields, :operator_seed_env, seed_var),
               :ok <- Config.validate_fields(fields),
               :ok <- agent_validate_genesis(opts.name, fields) do
            agent_create(paths, seed, opts.name, fields)
          end
        after
          release.()
        end

      {:error, _refused} = error ->
        error
    end
  end

  # P5 round-6 MEDIUM-1 + round-8 LOW-1: `new --force` is a write — the
  # most destructive one — so the single-writer rule applies exactly as on
  # set/retract, and ATOMICALLY: the CLI takes the daemon's lock with
  # O_EXCL (the create IS the liveness check — no window between decision
  # and destruction), clears the dir around the HELD lock, and releases
  # only after the fresh store is appended. A live daemon's store is never
  # destroyed out from under it, and a daemon can never seize the store
  # mid-rebuild. A fresh dir needs no lock: no store exists to hold.
  defp agent_new_admission(registry, paths, opts) do
    cond do
      not File.exists?(paths.dir) ->
        {:ok, fn -> :ok end}

      opts.force ->
        cond do
          # P5 HIGH-2 defense in depth: the name shape is validated at parse,
          # but a destructive delete re-proves the target is a DIRECT child
          # of the registry root before it runs
          Path.dirname(Path.expand(paths.dir)) != Path.expand(registry) ->
            {:error, {:invalid_agent_name, opts.name}}

          true ->
            case agent_take_lock(paths.store, opts.name) do
              :ok ->
                agent_clear_dir!(paths)
                {:ok, fn -> File.rm(agent_lock_path(paths.store)) end}

              {:error, {:agent_live, name}} ->
                {:error, {:agent_live_force, name}}

              {:error, _reason} = error ->
                error
            end
        end

      true ->
        {:error, {:agent_exists, opts.name}}
    end
  end

  # rm_rf every child EXCEPT the held lock file — the lock survives the
  # clear so no daemon can grab the store path before the fresh append
  defp agent_clear_dir!(paths) do
    lock = agent_lock_path(paths.store)

    for entry <- File.ls!(paths.dir),
        path = Path.join(paths.dir, entry),
        path != lock do
      File.rm_rf!(path)
    end

    :ok
  end

  # genesis is validated at new-time (premortem P1): the fallback the
  # harness steps back to must not be born broken — the EFFECTIVE key env
  # (the operator's override or the genesis DEEPSEEK_API_KEY) must be
  # present, unless the key is supplied encrypted.
  defp agent_validate_genesis(name, fields) do
    if Map.has_key?(fields, :api_key_enc) do
      :ok
    else
      env = Map.get(fields, :api_key_env, @agent_genesis.api_key_env)

      case System.get_env(env) do
        value when is_binary(value) and value != "" -> :ok
        _absent -> {:error, {:agent_key_missing, name, env}}
      end
    end
  end

  # P5 round-7 HIGH-1 (AC21): the operator seed VALUE never touches disk —
  # only its derived AUTHOR lands in the pointer. The keyring dir is created
  # empty; the daemon mints `agent.seed` (the agent's OWN identity) there at
  # first boot. Writing the seed beside the store would make the registry
  # dir alone both the ciphertext and its decrypt key, voiding AC20.
  defp agent_create(paths, seed, name, fields) do
    ts = agent_now_ms()

    with :ok <- agent_mkdir(paths.dir),
         :ok <- agent_mkdir(paths.keyring),
         :ok <- agent_write_pointer(paths, [Keys.author_for_seed(seed)]),
         {:ok, genesis} <- AgentEvents.agent_set(seed, ts, name, @agent_genesis),
         {:ok, seed_delta} <- AgentEvents.agent_set(seed, ts + 1, name, fields),
         :ok <- agent_append(paths.store, [genesis, seed_delta]) do
      {:ok, "agent #{name} created at #{paths.store}"}
    end
  end

  defp agent_mkdir(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir_failed, reason}}
    end
  end

  # the pointer is the LOCAL trust anchor (P5 H2): `operator_authors` pins
  # the operator author chain so the fold never infers operatorship from
  # self-asserted store timestamps. Rekey REPLACES the chain with the new
  # author only (P5 HIGH-3 — revocation); custody history lives in-store as
  # the old-signed handoff deltas.
  defp agent_write_pointer(paths, operator_authors) do
    json =
      JSON.encode!(%{
        "log_path" => paths.store,
        "keyring_dir" => paths.keyring,
        "operator_authors" => operator_authors
      })

    case File.write(paths.pointer, json) do
      :ok -> :ok
      {:error, reason} -> {:error, {:pointer_write_failed, paths.pointer, reason}}
    end
  end

  # nil for a pre-chain (legacy) pointer or an unreadable one — resolve/3
  # then falls back to legacy first-writer display semantics
  defp agent_pointer_chain(paths) do
    with {:ok, content} <- File.read(paths.pointer),
         {:ok, %{"operator_authors" => [_ | _] = chain}} <- JSON.decode(content) do
      chain
    else
      _legacy -> nil
    end
  end

  # ---- list / show (AC7)

  defp agent_list(opts) do
    registry = agent_registry(opts)

    case File.ls(registry) do
      {:error, _reason} ->
        {:ok, ""}

      {:ok, entries} ->
        lines =
          entries
          |> Enum.sort()
          |> Enum.flat_map(fn name ->
            paths = agent_paths(registry, name)

            case Config.resolve(
                   agent_load_set(paths.store),
                   name,
                   agent_pointer_chain(paths),
                   agent_pinned_author(paths.keyring)
                 ) do
              {:ok, view} -> [agent_list_line(view)]
              :not_found -> []
            end
          end)

        {:ok, Enum.join(lines, "\n")}
    end
  end

  defp agent_list_line(view) do
    soul_head =
      case view.soul do
        nil -> "-"
        soul -> soul |> String.split("\n", parts: 2) |> hd()
      end

    Enum.join([view.name, view.model || "-", view.base_url || "-", soul_head], "  ")
  end

  defp agent_show(opts) do
    paths = agent_paths(agent_registry(opts), opts.name)

    if File.exists?(paths.pointer) do
      set = agent_load_set(paths.store)

      case Config.resolve(
             set,
             opts.name,
             agent_pointer_chain(paths),
             agent_pinned_author(paths.keyring)
           ) do
        {:ok, view} ->
          {:ok, agent_render(view, set)}

        :not_found ->
          {:ok,
           "#{opts.name}: no live config (stream fully retracted) — " <>
             "boot falls through to the engine defaults"}
      end
    else
      {:error, {:unknown_agent, opts.name}}
    end
  end

  # the fold, one field per line; `api_key` prints the env NAME or the
  # ciphertext, never a plaintext value (AC19); the per-field heads print so
  # the operator can retract by id; tombstones surface (AC24)
  defp agent_render(view, set) do
    api_key =
      case view.api_key do
        {:env, name} -> "env " <> name
        {:enc, ciphertext} -> "enc " <> ciphertext
        nil -> "-"
      end

    fields = [
      "name: #{view.name}",
      "soul: #{view.soul || "-"}",
      "base_url: #{view.base_url || "-"}",
      "model: #{view.model || "-"}",
      "api_key: #{api_key}",
      "system_prompt: #{view.system_prompt || "-"}",
      "operator_seed_env: #{view.operator_seed_env || "-"}",
      "oracle_seed: #{view.oracle_seed || "-"}",
      "loop: #{view.loop || "-"}",
      "channel_socket: #{view.channel_socket || "-"}",
      "profile: #{view.profile || "-"}",
      "self_config: #{view.self_config}"
    ]

    heads =
      view.heads
      |> Enum.sort()
      |> Enum.map(fn {field, id} -> "head #{field} #{id}" end)

    Enum.join(fields ++ heads ++ agent_tombstone_lines(view.name, set), "\n")
  end

  defp agent_tombstone_lines(name, set) do
    for(
      {id, {claims, _sig}} <- set,
      %{
        type: "SecretTombstone",
        agent: {:entity, ^name, _ctx},
        tombstone: {:delta, target, _tctx},
        field: field
      } <- [Schema.resolve(claims)],
      do: "tombstone #{target} field=#{field} (#{id})"
    )
    |> Enum.sort()
  end

  # ---- set / unset / set-soul (AC8)

  defp agent_set_cmd(opts) do
    # the door runs BEFORE seed resolution: a seed VALUE handed to
    # --operator-seed-env must be refused as secret-shaped (AC21), not
    # misread as an unset env NAME
    agent_open(opts, fn paths, set, view ->
      with fields = agent_with_unsets(opts.fields, opts.unset),
           :ok <- Config.validate_fields(fields),
           {:ok, seed, _var} <- agent_signing_seed(opts, view, set, agent_pointer_chain(paths)),
           {:ok, fields} <- agent_stdin_key(opts, fields, seed) do
        case Config.changed_fields(view, fields) do
          changed when changed == %{} ->
            {:ok, "no change (the fold already carries these values)"}

          changed ->
            with {:ok, signed} <- AgentEvents.agent_set(seed, agent_now_ms(), opts.name, changed),
                 :ok <- agent_append(paths.store, [signed]) do
              names =
                changed |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort() |> Enum.join(", ")

              {:ok, "updated #{opts.name}: #{names}"}
            end
        end
      end
    end)
  end

  defp agent_with_unsets(fields, []), do: fields
  defp agent_with_unsets(fields, unset), do: Map.put(fields, :unset, unset)

  # ---- retract (AC13)

  defp agent_retract_cmd(opts) do
    agent_open(opts, fn paths, set, view ->
      with :ok <- agent_known_delta(set, opts.target),
           {:ok, seed, _var} <- agent_signing_seed(opts, view, set, agent_pointer_chain(paths)),
           {:ok, signed} <-
             AgentEvents.agent_retract(seed, agent_now_ms(), opts.name, opts.target),
           :ok <- agent_append(paths.store, [signed]) do
        {:ok, "retracted #{opts.target}"}
      end
    end)
  end

  # ---- rekey (AC20 premortem)

  defp agent_rekey(%{new_seed_env: nil}), do: {:error, :usage, @usage}

  # ONE handoff, TWO deltas, ONE pointer write.
  #
  # P5 HIGH-3 — rekey REVOKES: the pointer chain is REPLACED with the new
  # author ONLY. A leaked rotated-away seed folds as agent-authored/inert
  # from then on, never as operator. The custody record stays in-store: the
  # old-signed handoff delta attests the incoming env NAME. Because the old
  # author leaves the chain, its historical deltas turn non-operator too —
  # so the new seed re-asserts the FULL live fold (the snapshot, with any
  # {enc} secret re-encrypted) in the same append, and the config survives
  # the authority cut.
  #
  # P5 LOW-2 — ordering: store append FIRST, pointer write LAST. A crash
  # between the append and the pointer write leaves the OLD chain live:
  # every verb still resolves (the snapshot folds chain-inert; the old
  # operator's fold is intact), and the rekey completes on re-run with
  # `--operator-seed-env <OLD> --new-seed-env <NEW>`. Never a wedge.
  #
  # P5 round-7 HIGH-1 (AC21): the NEW seed is never imported to the keyring
  # — like at create, only its author reaches disk (the pointer chain).
  defp agent_rekey(opts) do
    agent_open(opts, fn paths, _set, view ->
      with :ok <- agent_live_view(view, opts.name),
           chain = agent_pointer_chain(paths),
           {:ok, old_seed, _var} <- agent_signing_seed(opts, view, nil, chain),
           {:ok, new_seed} <- agent_seed_from_env(opts.new_seed_env),
           {:ok, snapshot} <- agent_rekey_snapshot(view, old_seed, new_seed, opts),
           ts = agent_now_ms(),
           {:ok, handoff} <-
             AgentEvents.agent_set(old_seed, ts, opts.name, %{
               operator_seed_env: opts.new_seed_env
             }),
           {:ok, reassert} <- AgentEvents.agent_set(new_seed, ts + 1, opts.name, snapshot),
           :ok <- agent_append(paths.store, [handoff, reassert]),
           :ok <- agent_write_pointer(paths, [Keys.author_for_seed(new_seed)]) do
        {:ok,
         "rekeyed #{opts.name}: operator authority REPLACED by #{opts.new_seed_env}'s author — " <>
           "the old seed is revoked (its deltas fold as non-operator) and any {enc} secret " <>
           "now decrypts under the new seed"}
      end
    end)
  end

  # the new operator's re-assertion of the live fold — every present field,
  # with the {enc} arm re-encrypted under the new seed and the seed env
  # pointing at the new NAME
  defp agent_rekey_snapshot(view, old_seed, new_seed, opts) do
    base =
      [
        soul: view.soul,
        model: view.model,
        base_url: view.base_url,
        system_prompt: view.system_prompt,
        oracle_seed: view.oracle_seed,
        loop: view.loop,
        channel_socket: view.channel_socket,
        profile: view.profile,
        self_config: if(view.self_config, do: "true", else: "false"),
        operator_seed_env: opts.new_seed_env
      ]
      |> Enum.reject(fn {_field, value} -> is_nil(value) end)
      |> Map.new()

    case view.api_key do
      {:enc, ciphertext} ->
        with {:ok, plaintext} <- agent_decrypt(ciphertext, old_seed, view.name),
             {:ok, reencrypted} <- Secrets.encrypt(plaintext, new_seed) do
          {:ok, Map.put(base, :api_key_enc, reencrypted)}
        end

      {:env, env_name} ->
        {:ok, Map.put(base, :api_key_env, env_name)}

      nil ->
        {:ok, base}
    end
  end

  defp agent_decrypt(ciphertext, seed, name) do
    case Secrets.decrypt(ciphertext, seed) do
      {:ok, plaintext} -> {:ok, plaintext}
      {:error, :decrypt_failed} -> {:error, {:decrypt_failed, name}}
    end
  end

  # ---- tombstone (AC24 — the leaked-secret runbook)

  defp agent_tombstone(%{field: nil}), do: {:error, :usage, @usage}

  defp agent_tombstone(opts) do
    ts = agent_now_ms()

    agent_open(opts, fn paths, set, view ->
      with :ok <- agent_known_delta(set, opts.target),
           {:ok, seed, _var} <- agent_signing_seed(opts, view, set, agent_pointer_chain(paths)),
           {:ok, retraction} <- AgentEvents.agent_retract(seed, ts, opts.name, opts.target),
           {:ok, tombstone} <-
             AgentEvents.secret_tombstone(
               seed,
               ts + 1,
               opts.name,
               opts.target,
               opts.field,
               opts.rotated
             ),
           :ok <- agent_append(paths.store, [retraction, tombstone]) do
        {:ok,
         "tombstoned #{opts.target} (#{opts.field}) — the delta is retracted and the " <>
           "exposure is recorded; ROTATE the credential now (the leaked value is burned)"}
      end
    end)
  end

  # ---- shared agent machinery

  defp agent_registry(%{registry: dir}) when is_binary(dir), do: dir
  defp agent_registry(_opts), do: Path.join(Path.dirname(default_log_path()), "agents")

  defp agent_paths(registry, name) do
    dir = Path.join(registry, name)

    %{
      dir: dir,
      store: Path.join(dir, "store.jsonl"),
      keyring: Path.join(dir, "keyring"),
      pointer: Path.join(dir, "agent.json")
    }
  end

  # fold a store file WITHOUT booting :kyber (a second DurableStore on a
  # live log is the N1 trap): raw lines through the door, one delta set out.
  # A refused/torn line is skipped exactly as DurableStore's replay skips it.
  defp agent_load_set(store_path) do
    store_path
    |> Log.stream()
    |> Enum.reduce(DeltaSet.new(), fn line, set ->
      with {:ok, wire} <- JSON.decode(line),
           {:ok, merged} <- Store.admit(wire, set) do
        merged
      else
        _refused -> set
      end
    end)
  end

  # P5 round-3 M2 + round-8 LOW-1: single-writer, ATOMICALLY. A live
  # daemon's DurableStore subscription is in-process only — a direct append
  # behind its back diverges silently until restart. The old check-then-
  # append was a TOCTOU on an advisory read: a daemon could take the store
  # between the liveness decision and the append. Now the CLI acquires the
  # daemon's OWN lock file with O_EXCL for the duration of read-fold-append
  # — the create IS the liveness check — and removes it on every exit path.
  # Route live changes through the served channel (`kyber ctl set-config`);
  # offline appends run under the held lock.
  defp agent_open(opts, fun) do
    paths = agent_paths(agent_registry(opts), opts.name)

    cond do
      not File.exists?(paths.pointer) ->
        {:error, {:unknown_agent, opts.name}}

      true ->
        case agent_take_lock(paths.store, opts.name) do
          :ok ->
            try do
              set = agent_load_set(paths.store)

              view =
                case Config.resolve(
                       set,
                       opts.name,
                       agent_pointer_chain(paths),
                       agent_pinned_author(paths.keyring)
                     ) do
                  {:ok, view} -> view
                  :not_found -> nil
                end

              fun.(paths, set, view)
            after
              File.rm(agent_lock_path(paths.store))
            end

          {:error, _refused} = error ->
            error
        end
    end
  end

  @agent_lock_attempts 5

  defp agent_lock_path(store_path), do: store_path <> ".lock"

  # the daemon's own lock protocol (`<store>.lock`, OS pid inside, O_EXCL
  # create — see Daemon.do_take_lock), with one difference: our OWN OS pid
  # in an EXISTING lock counts as live (an in-VM daemon is still the
  # writer). Same `ps -p` posture as the daemon's reclaim (EPERM-safe); a
  # dead or garbage holder is reclaimed, a live one refuses.
  defp agent_take_lock(store_path, name) do
    do_agent_take_lock(agent_lock_path(store_path), name, @agent_lock_attempts)
  end

  defp do_agent_take_lock(_lock, name, 0), do: {:error, {:agent_live, name}}

  defp do_agent_take_lock(lock, name, attempts) do
    case File.open(lock, [:write, :exclusive, :binary]) do
      {:ok, io} ->
        with :ok <- IO.binwrite(io, System.pid()), :ok <- File.close(io) do
          :ok
        else
          {:error, reason} -> {:error, {:agent_lock_failed, reason}}
        end

      {:error, :eexist} ->
        if agent_lock_live?(lock) do
          {:error, {:agent_live, name}}
        else
          File.rm(lock)
          do_agent_take_lock(lock, name, attempts - 1)
        end

      {:error, reason} ->
        {:error, {:agent_lock_failed, reason}}
    end
  end

  defp agent_lock_live?(lock) do
    case File.read(lock) do
      {:ok, content} ->
        pid = String.trim(content)
        pid == System.pid() or agent_os_pid_alive?(pid)

      {:error, _unreadable} ->
        false
    end
  end

  defp agent_os_pid_alive?(pid_text) do
    case Integer.parse(pid_text) do
      {n, ""} when n > 0 ->
        match?({_, 0}, System.cmd("ps", ["-p", Integer.to_string(n)], stderr_to_stdout: true))

      _garbage ->
        false
    end
  end

  # P5 round-3 H1: the agent-admission pin for CLI folds — the agent author
  # derives from the registry keyring's `agent.seed` (the seed the daemon
  # boots with). Absent or garbage seed folds FAIL-CLOSED (`:none`): no
  # agent identity exists, so no agent-authored delta is admissible.
  defp agent_pinned_author(keyring_dir) do
    with {:ok, content} <- File.read(Path.join(keyring_dir, "agent.seed")),
         seed = content |> String.trim() |> String.downcase(),
         {:ok, <<_::binary-32>>} <- Base.decode16(seed, case: :mixed) do
      Keys.author_for_seed(seed)
    else
      _absent_or_garbage -> :none
    end
  end

  defp agent_view_or_nil(store_path, name, chain, agent_author) do
    case Config.resolve(agent_load_set(store_path), name, chain, agent_author) do
      {:ok, view} -> view
      :not_found -> nil
    end
  end

  defp agent_known_delta(set, id) do
    if Map.has_key?(set, id), do: :ok, else: {:error, {:unknown_delta, id}}
  end

  defp agent_live_view(nil, name), do: {:error, {:unknown_agent, name}}
  defp agent_live_view(_view, _name), do: :ok

  # the signing seed: the env NAME comes from --operator-seed-env, else the
  # fold's recorded operator_seed_env, else the latest env NAME in the store
  # BYTES (retraction negates the config value, but the store only learns —
  # a fully-retracted stream must still be amendable by its operator), else
  # KYBER_OPERATOR_SEED — the VALUE only ever rides the environment (M5/N4)
  defp agent_signing_seed(opts, view, set \\ nil, chain \\ nil) do
    var =
      opts.operator_seed_env || (view && view.operator_seed_env) ||
        agent_recorded_seed_env(set, opts.name) || "KYBER_OPERATOR_SEED"

    with {:ok, seed} <- agent_seed_from_env(var),
         :ok <- agent_operator_check(seed, var, chain) do
      {:ok, seed, var}
    end
  end

  # M2 (P5): under a pointer chain, the signing seed must derive the CURRENT
  # (last) operator author — a rotated-away seed fails loudly instead of
  # minting deltas the pinned fold treats as agent-authored
  defp agent_operator_check(_seed, _var, nil), do: :ok

  defp agent_operator_check(seed, var, chain) do
    if Keys.author_for_seed(seed) == List.last(chain),
      do: :ok,
      else: {:error, {:not_operator, var}}
  end

  defp agent_recorded_seed_env(nil, _name), do: nil

  defp agent_recorded_seed_env(set, name) do
    for(
      {id, {claims, _sig}} <- set,
      %{type: "AgentSet", agent: {:entity, ^name, _ctx}, operator_seed_env: env} <-
        [Schema.resolve(claims)],
      is_binary(env),
      do: {claims.timestamp, id, env}
    )
    |> Enum.sort()
    |> List.last()
    |> case do
      {_ts, _id, env} -> env
      nil -> nil
    end
  end

  defp agent_seed_from_env(var) do
    case System.get_env(var) do
      value when is_binary(value) and value != "" ->
        trimmed = String.trim(value)

        case Base.decode16(trimmed, case: :mixed) do
          {:ok, <<_::binary-32>>} -> {:ok, String.downcase(trimmed)}
          _garbage -> {:error, {:invalid_operator_seed, var}}
        end

      _absent ->
        {:error, {:no_operator_seed_env, var}}
    end
  end

  # a bare --api-key reads ONE line from stdin, encrypts under the operator
  # seed, and rides as api_key_enc — the plaintext exists only in this
  # unlogged window (AC20)
  defp agent_stdin_key(%{api_key_stdin: false}, fields, _seed), do: {:ok, fields}

  defp agent_stdin_key(_opts, fields, seed) do
    case IO.read(:stdio, :line) do
      line when is_binary(line) ->
        value = String.trim(line)

        if value == "" do
          {:error, :no_stdin_key}
        else
          with {:ok, ciphertext} <- Secrets.encrypt(value, seed) do
            {:ok, Map.put(fields, :api_key_enc, ciphertext)}
          end
        end

      _eof_or_error ->
        {:error, :no_stdin_key}
    end
  end

  defp agent_append(store_path, signed_list) do
    case Log.open(store_path) do
      {:ok, io} ->
        result =
          Enum.reduce_while(signed_list, :ok, fn signed, :ok ->
            case Log.append(io, Wire.envelope(signed)) do
              :ok -> {:cont, :ok}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          end)

        File.close(io)
        result

      {:error, reason} ->
        {:error, {:store_open_failed, store_path, reason}}
    end
  end

  defp agent_now_ms, do: 1.0 * System.system_time(:millisecond)

  defp agent_read_pointer(opts) do
    with :ok <- agent_valid_name(opts.agent) do
      agent_read_pointer_file(agent_paths(agent_registry(opts), opts.agent), opts)
    end
  end

  defp agent_read_pointer_file(paths, opts) do
    with {:ok, content} <- File.read(paths.pointer),
         {:ok, %{"log_path" => log, "keyring_dir" => keyring} = decoded}
         when is_binary(log) and is_binary(keyring) <- JSON.decode(content) do
      chain =
        case decoded do
          %{"operator_authors" => [_ | _] = authors} -> authors
          _legacy -> nil
        end

      {:ok, %{log_path: log, keyring_dir: keyring, operator_authors: chain}}
    else
      _other -> {:error, {:unknown_agent, opts.agent}}
    end
  end

  # the CLI flags the operator EXPLICITLY passed — merged LAST over the fold
  # (AC4: overrides win, never append deltas)
  defp daemon_override_opts(opts) do
    [
      model: opts.model,
      base_url: opts.base_url,
      system_prompt: opts.system_prompt,
      profile: opts.profile,
      channel_socket: opts.channel_socket,
      loop: opts.loop,
      oracle_seed: opts.oracle_seed,
      peer_port: opts.peer_port
    ]
    |> Enum.reject(fn {_key, value} -> value == nil end)
  end

  defp agent_boot_operator_seed(opts, view) do
    var = opts.operator_seed_env || (view && view.operator_seed_env)

    case var && System.get_env(var) do
      nil ->
        {:ok, nil}

      value ->
        case Base.decode16(String.trim(value), case: :mixed) do
          {:ok, <<_::binary-32>>} -> {:ok, String.downcase(String.trim(value))}
          _garbage -> {:error, :usage}
        end
    end
  end

  # an explicit --api-key-env overrides the fold; otherwise the fold's
  # tagged union resolves here: {:env, NAME} -> the environment (unset is
  # the AC18 legible refusal), {:enc, ct} -> decrypt under the operator seed
  defp agent_boot_api_key(%{api_key_env: env}, _view, _seed) when is_binary(env),
    do: {:ok, resolve_env_value(env)}

  defp agent_boot_api_key(_opts, nil, _seed), do: {:ok, nil}

  defp agent_boot_api_key(opts, view, operator_seed) do
    case view.api_key do
      nil ->
        {:ok, nil}

      {:env, name} ->
        case System.get_env(name) do
          value when is_binary(value) and value != "" -> {:ok, value}
          _absent -> {:error, {:agent_key_missing, view.name, name}}
        end

      {:enc, ciphertext} ->
        if operator_seed == nil do
          {:error,
           {:no_operator_seed_env,
            opts.operator_seed_env || view.operator_seed_env || "KYBER_OPERATOR_SEED"}}
        else
          agent_decrypt(ciphertext, operator_seed, view.name)
        end
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
        # nil = "not given" so a fold value can win under --agent (AC4);
        # the non-agent path defaults it to :absent at cmd_daemon
        oracle_seed: nil,
        # T17: boot from the registry pointer + AgentSet fold
        agent: nil,
        registry: nil
      },
      extra
    )
  end

  # L8: `--channel-socket` WITHOUT `--loop reactor` is a usage error, exit 2
  # (under :ack sends persist but get the T10 ack-loop answer — the refusal
  # is evidence-backed)
  defp daemon_opts([], opts) do
    # complete = the T10 explicit pair (--log + --keyring) OR the T17
    # pointer form (--agent <name>: log and keyring ride the pointer)
    complete = (is_binary(opts.log) and is_binary(opts.keyring)) or is_binary(opts.agent)

    cond do
      not complete -> {:error, :usage}
      opts.channel_socket != nil and opts.loop != :reactor -> {:error, :usage}
      true -> {:ok, opts}
    end
  end

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

  # T17: boot from the registry pointer (`--agent` is sugar over it; the
  # store implies the identity)
  defp daemon_opts(["--agent", name | rest], %{agent: nil} = opts) when name != "",
    do: daemon_opts(rest, %{opts | agent: name})

  defp daemon_opts(["--registry", dir | rest], %{registry: nil} = opts) when dir != "",
    do: daemon_opts(rest, %{opts | registry: dir})

  defp daemon_opts(_other, _opts), do: {:error, :usage}

  # T17 AC2/AC4: pointer -> store -> fold -> boot opts, with CLI flags
  # overriding the fold (overrides never append deltas). The tagged api_key
  # resolves to a VALUE only here, at the boot boundary: `{:env, NAME}` from
  # the environment (unset -> the AC18 legible refusal), `{:enc, ct}`
  # decrypted under the operator seed in the unlogged window.
  defp cmd_daemon(%{agent: agent} = opts) when is_binary(agent) do
    with {:ok, pointer} <- agent_read_pointer(opts),
         view =
           agent_view_or_nil(
             pointer.log_path,
             agent,
             pointer.operator_authors,
             agent_pinned_author(pointer.keyring_dir)
           ),
         {:ok, operator_seed} <- agent_boot_operator_seed(opts, view),
         {:ok, api_key} <- agent_boot_api_key(opts, view, operator_seed) do
      overrides = daemon_override_opts(opts)
      fold_opts = if view, do: Config.boot_opts(view, overrides), else: overrides

      boot_opts =
        fold_opts
        |> Keyword.delete(:api_key)
        |> Keyword.delete(:operator_seed_env)
        |> Keyword.merge(
          keyring_dir: pointer.keyring_dir,
          pulse_only: opts.pulse_only,
          narrate: true,
          operator_seed: operator_seed,
          api_key: api_key,
          # T17 (AC10/AC23): agent mode — the daemon subscribes to the T16
          # feed and hot-swaps on AgentSet deltas, with the CLI overrides
          # pinned across every re-fold
          agent: agent,
          overrides: overrides,
          # P5 H2: the pointer's operator author chain pins the fold — the
          # daemon never derives operatorship from store timestamps
          operator_authors: pointer.operator_authors
        )
        |> Keyword.put_new(:loop, :ack)
        |> Keyword.put_new(:oracle_seed, :absent)
        |> Keyword.merge(if(opts.tick_ms, do: [tick_ms: opts.tick_ms], else: []))

      case Daemon.boot(boot_opts) do
        {:ok, pid} ->
          %{log_path: log_path} = Daemon.status()
          {:ok, {:daemon, "daemon running on #{log_path}", pid}}

        {:error, reason} ->
          {:error, format_error(reason)}
      end
    else
      {:error, :usage} -> {:error, :usage, @usage}
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

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

  defp tui_opts(["--log", path | rest], %{log: nil} = opts),
    do: tui_opts(rest, %{opts | log: path})

  defp tui_opts(["--socket", path | rest], %{socket: nil} = opts),
    do: tui_opts(rest, %{opts | socket: path})

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

  defp extract_gateway_flags(["--token-env", var | rest], %{token_env: nil} = gateway)
       when var != "",
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

  # T17: the agent-identity one-liners
  defp format_error({:invalid_agent_name, name}),
    do:
      "invalid agent name #{inspect(name)} — a name is a single path component " <>
        "matching [a-z0-9][a-z0-9_-]* (no separators, no .., no absolute paths)"

  defp format_error({:agent_exists, name}),
    do: "agent #{name} already exists — pass --force to overwrite"

  defp format_error({:unknown_agent, name}),
    do: "unknown agent: #{name} (a ghost — run `kyber agent new #{name}` first)"

  defp format_error({:no_operator_seed_env, var}),
    do: "agent: the operator seed env #{var} is unset — export a 64-hex seed value in #{var}"

  defp format_error({:invalid_operator_seed, var}),
    do: "agent: #{var} does not hold a 64-hex seed — check the value exported in #{var}"

  defp format_error({:agent_key_missing, name, env}),
    do:
      "agent #{name}: the provider needs the API key named by #{env} — export #{env} in the environment, then retry"

  defp format_error({:invalid_field, field, message}), do: "#{field}: #{message}"

  defp format_error({:secret_shaped, field, message}),
    do: "#{field} looks secret-shaped — refused: #{message}"

  defp format_error(:plaintext_key_on_argv),
    do: "a key VALUE never rides argv (ps-visible) — " <> Config.repair()

  defp format_error(:no_stdin_key),
    do: "no key on stdin — pipe the secret value: echo $KEY | kyber agent set <name> --api-key"

  defp format_error({:agent_live, name}),
    do:
      "agent #{name} is live (a daemon holds its store lock) — a direct append would " <>
        "diverge from the running fold; route the change through the daemon: " <>
        "kyber ctl set-config"

  defp format_error({:agent_live_force, name}),
    do:
      "agent #{name} is live (a daemon holds its store lock) — refusing to destroy a " <>
        "running agent's store; stop it first (kyber daemon stop / kill the pid) or " <>
        "route changes through kyber ctl set-config"

  defp format_error({:agent_lock_failed, reason}),
    do:
      "could not take the store lock (#{inspect(reason)}) — the single-writer guard " <>
        "holds the lock across the append; check permissions beside the store"

  defp format_error({:unknown_delta, id}), do: "unknown delta: #{id}"

  defp format_error({:decrypt_failed, name}),
    do: "agent #{name}: the current operator seed cannot decrypt the stored key — wrong seed?"

  defp format_error({:not_operator, var}),
    do:
      "the seed in #{var} is not the CURRENT operator (authority was rekeyed away) — " <>
        "export the newest operator seed and retry"

  defp format_error({:not_operator, author, expected}),
    do:
      "boot seed derives #{author} but the pointer's current operator is #{expected} — " <>
        "export the newest operator seed (the rekey moved authority)"

  defp format_error(other), do: "error: #{inspect(other)}"
end
