import Config

# The suite never touches the user's real store or keyring: the log path and
# the keyring dir (T4) are per-run tmp dirs. The auto-started app (mix test
# boots :kyber once `mod:` is in mix.exs) uses this path; test_helper.exs then
# stops the app so the T2 suite's per-test start_supervised!({DurableStore,
# path}) keeps working. harness_test derives the keyring dir it passes from
# this env key (AC11 — the override is exercised; seeds land in tmp, never in
# the real ~/.kyber).
config :kyber,
  log_path:
    Path.join(
      System.tmp_dir!(),
      "kyber-test-#{System.unique_integer([:positive])}-#{System.system_time(:nanosecond)}/store.jsonl"
    ),
  keyring_dir:
    Path.join(
      System.tmp_dir!(),
      "kyber-test-#{System.unique_integer([:positive])}-#{System.system_time(:nanosecond)}/keyring"
    )

# T19: the dashboard tests boot KyberWeb.Application directly; the endpoint
# never binds a port in the suite (server: false — LiveViewTest drives it
# through the test conn).
config :kyber, KyberWeb.Endpoint,
  server: false,
  check_origin: false,
  secret_key_base: "kyber-test-secret-key-base-0123456789abcdef0123456789abcdef",
  live_view: [signing_salt: "kyber-test-salt"]
