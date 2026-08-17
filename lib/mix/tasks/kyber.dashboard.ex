defmodule Mix.Tasks.Kyber.Dashboard do
  @shortdoc "Run the kyber dashboard: store + reactor daemon + span collector + LiveView endpoint"

  @moduledoc """
  T19 run mode (M4, pinned): `mix kyber.dashboard` boots store + daemon
  (`loop: :reactor`) + the span collector + the Phoenix endpoint in ONE
  BEAM/supervision tree, then blocks (Ctrl-C unwinds the tree; the daemon's
  lock releases on SIGTERM's init:stop).

  A separate-BEAM dashboard (`mix phx.server` in one shell, `kyber daemon`
  in another) is the documented "nothing to show" state — view 1 renders an
  explicit banner when the collector or store is absent.

  Flags: `--log <path>` (store path; defaults to the configured
  `:kyber, :log_path`), `--keyring <dir>` (defaults to a tmp dir — the real
  `~/.kyber` is never touched), `--port <n>` (endpoint port, default 4000),
  plus the daemon's model flags (`--api-key-env`, `--operator-seed-env`,
  `--model`, `--base-url`, `--oracle-seed present|absent`). The reactor
  boots `engine: :none` unless an api key is supplied.

  A `:reactor` dashboard is a WRITER, not a viewer — it hosts the live
  daemon (M4: one tree per agent, so `ctl send` letters flow through it) and
  appends operational deltas whatever the flags say. What is guarded is the
  one standing write: `--oracle-seed present` mints the seed claim that
  authorizes model initiation, so ON THIS TASK it is admitted only against a
  store under the system tmp dir or one the operator marks with
  `--dev-store` (see `guard_oracle_seed/1`). The guard is scoped to this
  entry point, not to the store: `kyber daemon --oracle-seed present` mints
  the same claim unguarded, because an explicit flag on an explicit daemon
  boot is already the deliberate gate-open.
  """

  use Mix.Task

  @impl true
  def run(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        strict: [
          log: :string,
          keyring: :string,
          port: :integer,
          api_key_env: :string,
          operator_seed_env: :string,
          model: :string,
          base_url: :string,
          oracle_seed: :string,
          dev_store: :boolean
        ]
      )

    :ok = guard_oracle_seed(opts)

    if opts[:log], do: Application.put_env(:kyber, :log_path, opts[:log])

    if opts[:port] do
      endpoint_config = Application.get_env(:kyber, KyberWeb.Endpoint) || []

      Application.put_env(
        :kyber,
        KyberWeb.Endpoint,
        Keyword.put(endpoint_config, :http, port: opts[:port])
      )
    end

    # boots :kyber (the store, Kyber.Application) — the substrate tree
    Mix.Task.run("app.start")

    # the dashboard tree: collector + endpoint (ensures the Phoenix apps)
    case KyberWeb.Application.start(:normal, []) do
      {:ok, _sup} -> :ok
      {:error, reason} -> Mix.raise("dashboard tree failed to start: #{inspect(reason)}")
    end

    keyring = opts[:keyring] || Path.join(System.tmp_dir!(), "kyber-dashboard-keyring")
    File.mkdir_p!(keyring)

    # resolved ONCE, then reused: the SAME operator seed feeds the boot opt
    # and the engine's redact list (AC22 — see build_boot_opts/4)
    operator_seed = resolve_operator_seed(opts[:operator_seed_env])
    key = opts[:api_key_env] && System.get_env(opts[:api_key_env])

    case Kyber.Daemon.boot(build_boot_opts(opts, keyring, key, operator_seed)) do
      {:ok, _pid} ->
        port = opts[:port] || 4000
        Mix.shell().info("kyber dashboard running: http://localhost:#{port}/")
        # block: the tree keeps the BEAM alive until SIGINT/SIGTERM
        receive do
          :never -> :ok
        end

      {:error, reason} ->
        Mix.raise("daemon boot failed: #{inspect(reason)}")
    end
  end

  # The pure opt → boot-opts translation (the task's whole decision surface,
  # split out so it is testable without booting a tree).
  @doc false
  @spec build_boot_opts(keyword(), String.t(), String.t() | nil, String.t() | nil) :: keyword()
  def build_boot_opts(opts, keyring, key, operator_seed) do
    engine =
      case key do
        nil ->
          :none

        key ->
          # AC22 (P5 M1): the daemon's own reactor_opts seeds the handler's
          # redact list with the known secrets; a flat engine list bypasses
          # that path, so the dashboard seeds the SAME pair itself — the
          # operator seed must never survive to the wire.
          Keyword.new(
            api_key: key,
            model: opts[:model],
            base_url: opts[:base_url],
            redact: Enum.filter([key, operator_seed], &is_binary/1)
          )
      end

    [
      keyring_dir: keyring,
      loop: :reactor,
      channel_socket: :default,
      operator_seed: operator_seed,
      oracle_seed: oracle_seed(opts[:oracle_seed]),
      engine: engine,
      narrate: true
    ]
  end

  # The guard covers ONE write on ONE entry point: the seed claim minted by
  # `mix kyber.dashboard --oracle-seed present`. That claim is the standing
  # authorization for model initiation and it outlives the dashboard
  # process, so here it is admitted only against a dev store. The
  # dashboard's reactor writes either way (refusals, checkpoints, the
  # agent's own deltas — it IS the live daemon host, M4); the seed claim is
  # the write that wants a deliberate gate-open, not a side effect of
  # starting a viewer.
  #
  # This is NOT store-wide protection, and does not pretend to be: `kyber
  # daemon --oracle-seed present` and the Discord gateway mint the identical
  # claim unguarded, by design. Those are the operator's deliberate boot
  # paths — an explicit flag on an explicit daemon boot IS the deliberate
  # gate-open. The dashboard is the one entry point where the flag can ride
  # along casually with a viewer, which is why it alone asks.
  #
  # Two ways to be a dev store, either sufficient: the `--log` path lies
  # under the system tmp dir (flag-free, so tests and throwaway stores need
  # nothing extra), or the operator passes `--dev-store` (the deliberate
  # opt-in for a store anywhere else).
  #
  # tmp-ness is a path-COMPONENT prefix, not a string prefix: `/tmpdata` is
  # not under `/tmp`. TMPDIR is user-settable, which is why it cannot be the
  # only admission — a relocated TMPDIR moves the flag-free case, it does
  # not widen it.
  @doc false
  @spec guard_oracle_seed(keyword()) :: :ok
  def guard_oracle_seed(opts) do
    if oracle_seed(opts[:oracle_seed]) == :present and
         not (tmp_store?(opts[:log]) or opts[:dev_store] == true) do
      Mix.raise(
        "--oracle-seed present would open the oracle gate on a real store: the boot mints " <>
          "a seed claim, the standing authorization for model initiation. (The dashboard's " <>
          "reactor still appends operational deltas — refusals, checkpoints — the seed " <>
          "claim is the one write that wants a deliberate gate-open.) The dashboard is a " <>
          "viewer; the deliberate gate-open is: kyber daemon --oracle-seed present, or " <>
          "kyber agent set <name> --oracle-seed present. Pass --dev-store if this store " <>
          "really is a dev store."
      )
    end

    :ok
  end

  defp tmp_store?(nil), do: false

  defp tmp_store?(log) do
    List.starts_with?(
      Path.split(Path.expand(log)),
      Path.split(Path.expand(System.tmp_dir!()))
    )
  end

  # T19 (P5 LOW): strict, mirroring resolve_operator_seed/1 — a typo'd
  # `--oracle-seed presnt` refuses loudly rather than coercing to :absent
  # (a silently oracle-less daemon refuses every model initiation).
  defp oracle_seed("present"), do: :present
  defp oracle_seed("absent"), do: :absent
  defp oracle_seed(nil), do: :absent

  defp oracle_seed(other),
    do: Mix.raise("--oracle-seed must be present or absent, got #{inspect(other)}")

  # Mirrors Kyber.CLI.resolve_operator_seed/1: an absent env NAME or an unset
  # env is a nil seed (sends refuse — the no_operator_seed gate); a set value
  # must be 64-hex. The VALUE never rides argv and is never printed.
  @doc false
  @spec resolve_operator_seed(String.t() | nil) :: String.t() | nil
  def resolve_operator_seed(nil), do: nil

  def resolve_operator_seed(var) do
    case System.get_env(var) do
      nil ->
        nil

      value ->
        case Base.decode16(String.trim(value), case: :mixed) do
          {:ok, <<_::binary-32>>} -> String.downcase(String.trim(value))
          _garbage -> Mix.raise("#{var} must be a 64-hex (32-byte) operator seed")
        end
    end
  end
end
