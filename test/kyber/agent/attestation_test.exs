defmodule Kyber.Agent.AttestationTest do
  @moduledoc """
  T14c AC3 — the operator-key boot attestation: a boot under an operator
  key records a store-visible attestation (operator, agent, boot claims);
  the attestation is content-derived and verifiable from store state alone
  (`Attestation.verified?/2` — pointer resolution + non-self guard +
  unretracted seed-claim target + author-field == operator-pointer binding
  + REAL Ed25519 on the claim bytes; P3's tamper leg kills stub-verify).

  The attested seed claim is THE oracle seed claim the daemon asserts at
  boot (`oracle_seed: :present`, T14a pin 17 — signed by the daemon's boot
  key, fixed content + fixed ts => fixed id across boots); T14c's
  operator-key signing is the ATTESTATION itself, never the seed claim.

  Anti-placebo: the positive leg's exactly-one count blocks vacuous passes;
  the second boot is pinned as union-no-op (the re-derived claim merges to
  the same delta — count unchanged); opt-absent boots attest nothing; an
  agent-signed forgery, a third-party forgery (pinned pointers, wrong
  signer — A2's hole), and a flipped signed-payload byte all fail
  verification.
  """
  use ExUnit.Case, async: false

  alias Kyber.{Daemon, DurableStore, Keys, Schema, Store, Wire}
  alias Kyber.Agent.{Attestation, Events}
  alias Rhizomatic.{Delta, Signer}

  @agent_seed String.duplicate("b2", 32)
  @operator_seed String.duplicate("7f", 32)
  @third_seed String.duplicate("9c", 32)
  @oracle_seed_ts 1_700_000_000_000.0

  @agent_author Keys.author_for_seed(@agent_seed)
  @operator_author Keys.author_for_seed(@operator_seed)
  @third_author Keys.author_for_seed(@third_seed)

  defp stop_app do
    case Application.stop(:kyber) do
      :ok -> :ok
      {:error, {:not_started, :kyber}} -> :ok
      other -> other
    end
  end

  setup do
    config_log_path = Application.get_env(:kyber, :log_path)
    uniq = "#{System.os_time()}-#{System.unique_integer([:positive])}"
    key_dir = Path.join(System.tmp_dir!(), "kyber-t14c-attest-keyring-#{uniq}")
    log_dir = Path.join(System.tmp_dir!(), "kyber-t14c-attest-log-#{uniq}")
    File.mkdir_p!(key_dir)
    File.mkdir_p!(log_dir)
    # fixed agent identity across boots: the daemon imports KYBER_SEED on
    # first load (Keys.load_agent_seed/1), so two cold boots over fresh
    # keyring dirs hold the SAME agent key — the attestation's content
    # address is reproducible
    System.put_env("KYBER_SEED", @agent_seed)
    :ok = Keys.import_human_seed(String.duplicate("cd", 32), key_dir)

    stop_app()
    Application.put_env(:kyber, :log_path, Path.join(log_dir, "store.jsonl"))
    {:ok, _} = Application.ensure_all_started(:kyber)

    on_exit(fn ->
      Daemon.stop()
      stop_app()
      Application.put_env(:kyber, :log_path, config_log_path)
      System.delete_env("KYBER_SEED")
      File.rm_rf(key_dir)
      File.rm_rf(log_dir)
    end)

    {:ok, key_dir: key_dir}
  end

  defp boot_daemon!(key_dir, opts \\ []) do
    boot_opts =
      Keyword.merge(
        [
          keyring_dir: key_dir,
          tick_ms: :manual,
          loop: :reactor,
          oracle_seed: :present,
          budget_cap: 32
        ],
        opts
      )

    assert {:ok, _pid} = Daemon.boot(boot_opts)
  end

  defp attestations(set) do
    Enum.filter(set, fn {_id, {claims, _sig}} ->
      match?(%{type: "BootAttestation"}, Schema.resolve(claims))
    end)
  end

  defp seed_claim(set) do
    Enum.find(set, fn {_id, {claims, _sig}} ->
      match?(%{pointers: [%{role: "seed"} | _rest]}, claims)
    end)
  end

  # ------------------------------------------------------------------ tests

  test "AC3: a boot under an operator key records EXACTLY ONE store-visible attestation — pinned pointers, store-derived ts, verified? true",
       ctx do
    boot_daemon!(ctx.key_dir, operator_seed: @operator_seed)

    set = DurableStore.set()
    assert [one] = attestations(set)
    {_id, {claims, sig}} = one
    typed = Schema.resolve(claims)

    # the three pinned pointers — the boot pointer targets THE oracle seed
    # claim the daemon asserted at boot
    {seed_id, {seed_claims, _seed_sig}} = seed_claim(set)
    assert typed.operator == {:entity, @operator_author, "attests"}
    assert typed.agent == {:entity, @agent_author, "attested"}
    assert typed.boot == {:delta, seed_id, "booted_under"}

    # ts = the seed claim's claims.timestamp — the only store-derived clock
    # at boot; never wall-clock
    assert claims.timestamp == seed_claims.timestamp
    assert claims.timestamp == @oracle_seed_ts

    # signed with the OPERATOR seed: the author field IS the operator's
    # pubkey and the signature verifies over the claim bytes
    assert claims.author == @operator_author
    assert Signer.verify(claims, sig)

    # verifiable from store state alone — pure, zero I/O
    assert Attestation.verified?(set, @agent_author)
  end

  test "AC3: a second cold boot over the same store emits nothing — union-no-op, delta count unchanged",
       ctx do
    boot_daemon!(ctx.key_dir, operator_seed: @operator_seed)
    set1 = DurableStore.set()
    size1 = map_size(set1)
    assert [_one] = attestations(set1)

    # cold re-boot on the SAME log: the daemon re-asserts the seed claim and
    # the reactor re-emits the attestation — both merge to the SAME content
    # addresses (fixed agent key + fixed seed ts), so the store is unchanged
    Daemon.stop()
    boot_daemon!(ctx.key_dir, operator_seed: @operator_seed)

    set2 = DurableStore.set()
    assert map_size(set2) == size1
    assert [_one] = attestations(set2)
  end

  test "AC3: an opt-absent boot attests nothing — the operator_seed default nil leaves existing boots unchanged",
       ctx do
    boot_daemon!(ctx.key_dir)

    set = DurableStore.set()
    assert attestations(set) == []
    # the oracle seed is still asserted — the boot happened, un-attested
    assert seed_claim(set) != nil
  end

  test "AC3: an agent-signed forgery fails verification — the operator cannot attest its own boot",
       ctx do
    boot_daemon!(ctx.key_dir, operator_seed: @operator_seed)
    set = DurableStore.set()
    {seed_id, {seed_claims, _sig}} = seed_claim(set)

    # the genuine attestation is dropped — the forged claim must stand
    # alone (a genuine sibling in the set would still verify)
    {genuine_id, _genuine} = hd(attestations(set))
    set = Map.delete(set, genuine_id)

    # forged with the AGENT seed: the operator pointer names the agent
    # itself — operator == agent, the non-self guard refuses
    {:ok, forged_signed} =
      Events.boot_attestation(@agent_seed, seed_claims.timestamp, @agent_author, seed_id)

    {forged_claims, forged_sig} = forged_signed
    forged_id = Delta.id_hex(forged_claims)
    forged_set = Map.put(set, forged_id, {forged_claims, forged_sig})

    refute Attestation.verified?(forged_set, @agent_author)
  end

  test "AC3: a third-party forgery fails verification — a claim carrying the pinned pointers but signed by a DIFFERENT key (A2's hole)",
       ctx do
    boot_daemon!(ctx.key_dir, operator_seed: @operator_seed)
    set = DurableStore.set()
    {seed_id, {seed_claims, _sig}} = seed_claim(set)

    # the pointers name the REAL operator; the claim is signed by a third
    # key — author-field == operator-pointer binding refuses it. The
    # genuine attestation is dropped first — the forgery must stand alone.
    {genuine_id, _genuine} = hd(attestations(set))
    set = Map.delete(set, genuine_id)

    raw = %{
      timestamp: seed_claims.timestamp,
      author: @third_author,
      pointers: [
        %{role: "operator", target: {:entity, @operator_author, "attests"}},
        %{role: "agent", target: {:entity, @agent_author, "attested"}},
        %{role: "boot", target: {:delta, seed_id, "booted_under"}},
        %{role: "type", target: {:entity, "BootAttestation", "instances"}}
      ]
    }

    {:ok, claims} = Delta.validate(raw)
    {:ok, sig} = Keys.sign(claims, @third_seed)
    forged_id = Delta.id_hex(claims)
    forged_set = Map.put(set, forged_id, {claims, sig})

    refute Attestation.verified?(forged_set, @agent_author)
  end

  test "AC3 tamper leg: flipping ONE signed-payload byte makes verification false — real Ed25519, never a stub",
       ctx do
    boot_daemon!(ctx.key_dir, operator_seed: @operator_seed)
    set = DurableStore.set()
    [_one] = attestations(set)
    {genuine_id, {claims, sig}} = hd(attestations(set))

    # the genuine claim is dropped — the tampered claim must stand alone
    set = Map.delete(set, genuine_id)

    # flip the signed payload: the timestamp rides the signed bytes, so
    # verification must fail even though every pointer still resolves
    tampered = %{claims | timestamp: claims.timestamp + 1.0}
    tampered_id = Delta.id_hex(tampered)
    tampered_set = Map.put(set, tampered_id, {tampered, sig})

    refute Attestation.verified?(tampered_set, @agent_author)
    refute Signer.verify(tampered, sig)
  end
end
