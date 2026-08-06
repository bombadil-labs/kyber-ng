import Config

# The durable store's default log path (T3): on a fresh account the parent
# dir does not exist yet — Kyber.Application mkdir_p's it at boot, so the
# first append lands instead of returning {:error, :persist_failed} (AC8).
# config/test.exs overrides this to a tmp dir so the suite never touches the
# user's real store.
# P5 guard (low finding 2): System.user_home() returns "" when HOME is unset —
# Path.join("", ".kyber/store.jsonl") would be a CWD-relative path, silently
# placing the real store in the working directory. Refuse loudly instead.
home = System.user_home()

if home == "" do
  raise "kyber: cannot resolve the default log_path — HOME is unset " <>
          "(System.user_home() is empty). Set config :kyber, log_path to an " <>
          "absolute path explicitly."
end

config :kyber, log_path: Path.join(home, ".kyber/store.jsonl")

# env-specific config (test.exs overrides log_path to a tmp dir). Imported only
# for :test so dev/prod runs need no extra config files (T3 touches config/
# only for config.exs + test.exs).
if config_env() == :test do
  import_config "test.exs"
end
