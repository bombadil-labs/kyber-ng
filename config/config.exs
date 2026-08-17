import Config

# The durable store's default log path (T3): on a fresh account the parent
# dir does not exist yet — Kyber.Application mkdir_p's it at boot, so the
# first append lands instead of returning {:error, :persist_failed} (AC8).
# The keyring dir (T4) defaults to the same home (.kyber) — the harness has
# NO runtime keyring default; the caller's arg is the only source (the
# config value is for App env, overridden to a tmp dir in test.exs).
# config/test.exs overrides both to tmp dirs so the suite never touches the
# user's real store or keyring.
# P5 guard (low finding 2): System.user_home() returns "" when HOME is unset —
# Path.join("", ".kyber/store.jsonl") would be a CWD-relative path, silently
# placing the real store in the working directory. Refuse loudly instead.
home = System.user_home()

if home == "" do
  raise "kyber: cannot resolve the default log_path — HOME is unset " <>
          "(System.user_home() is empty). Set config :kyber, log_path to an " <>
          "absolute path explicitly."
end

config :kyber,
  log_path: Path.join(home, ".kyber/store.jsonl"),
  keyring_dir: Path.join(home, ".kyber")

# T19 dashboard track (AGENTS.md rail exception 2026-08-14): the in-repo
# Phoenix LiveView dashboard. The endpoint config lives under :kyber (the
# dashboard modules live in the :kyber app — there is no separate
# :kyber_web OTP application; KyberWeb.Application boots it on the
# dashboard path only, so the substrate escript never loads Phoenix).
# Phoenix's json_library is the stdlib JSON module (no jason dep).
config :phoenix, :json_library, JSON

config :kyber, KyberWeb.Endpoint,
  url: [host: "localhost"],
  http: [port: 4000],
  secret_key_base: "kyber-dashboard-dev-secret-key-base-0123456789abcdef0123456789abcdef",
  live_view: [signing_salt: "kyber-live-salt"],
  render_errors: [view: KyberWeb.ErrorHTML, accepts: ~w(html)],
  check_origin: false,
  server: true

# env-specific config (test.exs overrides log_path AND the endpoint config to
# tmp/offline values). Imported only for :test so dev/prod runs need no extra
# config files (T3 touches config/ only for config.exs + test.exs). The T19
# endpoint block above sits BEFORE this import so the test overrides win.
if config_env() == :test do
  import_config "test.exs"
end
