defmodule Mix.Tasks.Kyber.DashboardTest do
  @moduledoc """
  T19 (P5) — the dashboard task's PURE decision surface: the parsed-opt →
  boot-opts translation and the operator-seed resolution. The task's run/1
  boots a whole supervision tree and then blocks forever, so nothing here
  ever calls it; the translation is exercised directly.

  What is pinned: the flat engine shape (no `:llm` wrapper — the reactor
  builds the handler), the AC22 redact seeding (api key AND operator seed,
  so neither survives to the wire on this path), the strict `--oracle-seed`
  parse, the viewer refusal of `--oracle-seed present` on a real store, and
  the 64-hex operator-seed gate.
  """

  use ExUnit.Case, async: false

  alias Mix.Tasks.Kyber.Dashboard

  # never a real key or a real seed — test-local literals only
  @key "test-key-never-real"
  @seed_hex String.duplicate("AB", 32)

  defp env_var(value) do
    name = "KYBER_DASHBOARD_TEST_#{System.unique_integer([:positive])}"
    if value, do: System.put_env(name, value)
    on_exit(fn -> System.delete_env(name) end)
    name
  end

  # -------------------------------------------------------- the engine shape

  test "no api key resolves to engine: :none" do
    opts = Dashboard.build_boot_opts([], "/tmp/keyring", nil, nil)

    assert opts[:engine] == :none
    assert opts[:loop] == :reactor
    assert opts[:channel_socket] == :default
    assert opts[:keyring_dir] == "/tmp/keyring"
    assert opts[:narrate] == true
  end

  test "an api key builds the FLAT engine shape — no :llm wrapper" do
    opts =
      Dashboard.build_boot_opts(
        [model: "m-x", base_url: "https://example.invalid/v1"],
        "/tmp/keyring",
        @key,
        nil
      )

    engine = opts[:engine]
    assert is_list(engine)
    assert engine[:llm] == nil
    assert engine[:api_key] == @key
    assert engine[:model] == "m-x"
    assert engine[:base_url] == "https://example.invalid/v1"
  end

  test "AC22: the api key AND the operator seed seed the engine's redact list" do
    seed = String.downcase(@seed_hex)
    opts = Dashboard.build_boot_opts([], "/tmp/keyring", @key, seed)

    assert opts[:engine][:redact] == [@key, seed]
    # the SAME resolved value rides the boot opt — one resolution, two uses
    assert opts[:operator_seed] == seed
  end

  test "an absent operator seed leaves the api key alone in the redact list" do
    opts = Dashboard.build_boot_opts([], "/tmp/keyring", @key, nil)

    assert opts[:engine][:redact] == [@key]
    assert opts[:operator_seed] == nil
  end

  # -------------------------------------------------------- the oracle seed

  test "--oracle-seed converts to an atom, and refuses anything else" do
    assert Dashboard.build_boot_opts([oracle_seed: "present"], "/k", nil, nil)[:oracle_seed] ==
             :present

    assert Dashboard.build_boot_opts([oracle_seed: "absent"], "/k", nil, nil)[:oracle_seed] ==
             :absent

    assert Dashboard.build_boot_opts([], "/k", nil, nil)[:oracle_seed] == :absent

    # T19 (P5 LOW): a typo is a loud refusal, never a silent coercion to
    # :absent (which would refuse every model initiation with no signal)
    assert_raise Mix.Error, ~r/--oracle-seed must be present or absent/, fn ->
      Dashboard.build_boot_opts([oracle_seed: "presnt"], "/k", nil, nil)
    end
  end

  test "--oracle-seed present is refused unless the store is a tmp dev store" do
    real = Path.join(System.user_home!(), ".kyber/store.jsonl")
    tmp = Path.join(System.tmp_dir!(), "kyber-dashboard-test/store.jsonl")

    error =
      assert_raise Mix.Error, fn ->
        Dashboard.guard_oracle_seed(oracle_seed: "present", log: real)
      end

    assert error.message =~ "would open the oracle gate on a real store"
    assert error.message =~ "kyber agent set <name> --oracle-seed present"

    # no --log at all resolves to the configured store — also a real one
    assert_raise Mix.Error, fn -> Dashboard.guard_oracle_seed(oracle_seed: "present") end

    assert Dashboard.guard_oracle_seed(oracle_seed: "present", log: tmp) == :ok
  end

  test "the guard is silent for --oracle-seed absent, whatever the store" do
    real = Path.join(System.user_home!(), ".kyber/store.jsonl")

    assert Dashboard.guard_oracle_seed(oracle_seed: "absent", log: real) == :ok
    assert Dashboard.guard_oracle_seed(log: real) == :ok

    # the strict parse still runs ahead of the store check
    assert_raise Mix.Error, ~r/--oracle-seed must be present or absent/, fn ->
      Dashboard.guard_oracle_seed(oracle_seed: "presnt", log: real)
    end
  end

  # ---------------------------------------------------- the operator seed env

  test "an absent env NAME is a nil operator seed" do
    assert Dashboard.resolve_operator_seed(nil) == nil
  end

  test "a named but UNSET env is a nil operator seed" do
    assert Dashboard.resolve_operator_seed(env_var(nil)) == nil
  end

  test "a 64-hex env value resolves downcased" do
    assert Dashboard.resolve_operator_seed(env_var(@seed_hex)) == String.downcase(@seed_hex)
  end

  test "a surrounding-whitespace 64-hex value still resolves" do
    assert Dashboard.resolve_operator_seed(env_var("  #{@seed_hex}\n")) ==
             String.downcase(@seed_hex)
  end

  test "a non-hex or wrong-length env value refuses loudly" do
    garbage = env_var("not-a-seed")
    short = env_var(String.duplicate("ab", 16))

    assert_raise Mix.Error, ~r/must be a 64-hex \(32-byte\) operator seed/, fn ->
      Dashboard.resolve_operator_seed(garbage)
    end

    assert_raise Mix.Error, ~r/must be a 64-hex \(32-byte\) operator seed/, fn ->
      Dashboard.resolve_operator_seed(short)
    end
  end

  test "the refusal message names the env VAR, never the value" do
    name = env_var("not-a-seed")

    error = assert_raise Mix.Error, fn -> Dashboard.resolve_operator_seed(name) end

    assert error.message =~ name
    refute error.message =~ "not-a-seed"
  end
end
