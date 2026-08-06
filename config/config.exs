import Config

# The durable store's default log path (T3): on a fresh account the parent
# dir does not exist yet — Kyber.Application mkdir_p's it at boot, so the
# first append lands instead of returning {:error, :persist_failed} (AC8).
# config/test.exs overrides this to a tmp dir so the suite never touches the
# user's real store.
config :kyber, log_path: Path.join(System.user_home(), ".kyber/store.jsonl")

# env-specific config (test.exs overrides log_path to a tmp dir). Imported only
# for :test so dev/prod runs need no extra config files (T3 touches config/
# only for config.exs + test.exs).
if config_env() == :test do
  import_config "test.exs"
end
