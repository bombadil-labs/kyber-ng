import Config

# The suite never touches the user's real store: the log path is a per-run
# tmp dir. The auto-started app (mix test boots :kyber once `mod:` is in
# mix.exs) uses this path; test_helper.exs then stops the app so the T2
# suite's per-test start_supervised!({DurableStore, path}) keeps working.
config :kyber,
  log_path:
    Path.join(
      System.tmp_dir!(),
      "kyber-test-#{System.unique_integer([:positive])}-#{System.system_time(:nanosecond)}/store.jsonl"
    )
