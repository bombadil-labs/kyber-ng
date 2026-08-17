defmodule Kyber.Agent.T19OracleSeedBootTest do
  @moduledoc """
  T19 round-3 — the boot-time oracle seed assertion (`oracle_seed: :present`).

  Properties, all read off store state: the assert is idempotent for THIS
  daemon's own live claim (a second boot appends no line to the log) but not
  for a foreign author's, it re-opens after a retraction (a store whose only
  seed claim is retracted gets a NEW claim at a fresh timestamp, so the
  retraction cannot absorb it and the reactor's gate is open again), it
  steps the timestamp when the id it would mint is already negated, and it
  survives a peer that pre-negates every id the fixed-ts ladder can derive
  (the fallback mint carries a nonce, so its id is not pre-computable).

  Round 6 adds the D6 hot path's half: closing the gate retracts EVERY live
  seed claim (a store legitimately holds more than one), opening it is
  author-scoped the way the boot assert is, and the postcondition confirms
  the claim this daemon actually minted rather than any live seed-ish one.

  Round 7 pins the close path to the REACTOR's definition of a gate claim
  (first pointer role "seed", any target), so a claim the reactor counts is
  a claim the close negates, and surfaces flips the daemon could not honor
  as `gate_flip_failures` in status.

  Round 8 makes the two retraction reads agree pointer-for-pointer (a claim
  whose SECOND `negates` pointer targets the seed closes the gate for the
  reactor too), proves the fail-soft boot end to end against a REAL refused
  append rather than the counter helper, and pins the close path's honesty:
  each foreign retraction is attributed, a repeated `absent` fold re-negates
  nothing, and a boot that could not mint says which of the two it is —
  refuse-only, or open on someone else's claim.

  Same discipline as reactor_test: tmp store + tmp keyring per test,
  `tick_ms: :manual`, no `Process.sleep`.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Kyber.{Daemon, DurableStore, Events, Keys, Schema, Wire}
  alias Kyber.Agent.Events, as: AgentEvents
  alias Rhizomatic.Delta

  @human_seed String.duplicate("cd", 32)
  @foreign_seed String.duplicate("ef", 32)
  @operator_seed String.duplicate("7f", 32)
  @oracle_seed_ts 1_700_000_000_000.0
  @oracle_pointer %{role: "seed", target: {:entity, "oracle", "seed"}}

  setup do
    keyring_dir = Application.get_env(:kyber, :keyring_dir)
    config_log_path = Application.get_env(:kyber, :log_path)

    uniq = "#{System.unique_integer([:positive])}-#{System.system_time(:nanosecond)}"
    key_dir = Path.join(keyring_dir, "kyber-t19os-key-#{uniq}")
    log_dir = Path.join(System.tmp_dir!(), "kyber-t19os-log-#{uniq}")
    log_path = Path.join(log_dir, "store.jsonl")
    File.mkdir_p!(key_dir)
    File.mkdir_p!(log_dir)
    assert :ok = Keys.import_human_seed(@human_seed, key_dir)
    assert {:ok, agent_seed} = Keys.mint_agent_seed(key_dir)

    stop_app()
    Application.put_env(:kyber, :log_path, log_path)
    assert {:ok, _} = Application.ensure_all_started(:kyber)

    on_exit(fn ->
      Daemon.stop()
      stop_app()
      Application.put_env(:kyber, :log_path, config_log_path)
      File.rm_rf(key_dir)
      File.rm_rf(log_dir)
    end)

    {:ok, keyring_dir: key_dir, agent_seed: agent_seed, log_path: log_path}
  end

  defp stop_app do
    case Application.stop(:kyber) do
      :ok -> :ok
      {:error, {:not_started, :kyber}} -> :ok
      other -> other
    end
  end

  defp boot(ctx) do
    Daemon.boot(
      keyring_dir: ctx.keyring_dir,
      tick_ms: :manual,
      loop: :reactor,
      oracle_seed: :present,
      budget_cap: 32,
      test_pid: self()
    )
  end

  defp boot!(ctx) do
    assert {:ok, _pid} = boot(ctx)
  end

  # the D6 shape: an agent identity, so the daemon subscribes to the store
  # and an operator AgentSet re-folds the config mid-session
  defp boot_agent!(ctx) do
    assert {:ok, _pid} =
             Daemon.boot(
               keyring_dir: ctx.keyring_dir,
               tick_ms: :manual,
               loop: :reactor,
               oracle_seed: :present,
               agent: "mokosh",
               operator_seed: @operator_seed,
               budget_cap: 32,
               test_pid: self()
             )
  end

  defp append_set!(ts, fields) do
    {:ok, signed} = AgentEvents.agent_set(@operator_seed, ts, "mokosh", fields)
    wire = Wire.envelope(signed)
    assert :ok = DurableStore.append(wire)
    wire["id"]
  end

  defp seed_claims do
    for {id, {claims, _sig}} <- DurableStore.set(),
        match?([%{role: "seed"} | _rest], claims.pointers),
        do: {id, claims}
  end

  defp signed_wire(seed, pointers, ts) do
    raw = %{timestamp: ts, author: Keys.author_for_seed(seed), pointers: pointers}
    {:ok, claims} = Delta.validate(raw)
    {:ok, sig} = Keys.sign(claims, seed)
    Wire.envelope({claims, sig})
  end

  defp seed_wire_id(seed, ts), do: signed_wire(seed, [@oracle_pointer], ts)["id"]

  defp negate!(seed, id) do
    wire =
      signed_wire(
        seed,
        [%{role: "negates", target: {:delta, id, "retracted"}}],
        1_754_600_000_000.0
      )

    assert :ok = DurableStore.append(wire)
  end

  defp negated?(id) do
    Enum.any?(DurableStore.set(), fn {_id, {claims, _sig}} ->
      Enum.any?(claims.pointers, &match?(%{role: "negates", target: {:delta, ^id, _ctx}}, &1))
    end)
  end

  # the LOG, not the set: the set dedups by content id, so a re-append of an
  # identical claim is invisible there — the append-only log records the line
  defp logged_seed_lines(ctx) do
    ctx.log_path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.filter(fn line ->
      {:ok, wire} = Wire.decode(line)
      match?([%{"role" => "seed"} | _rest], wire["claims"]["pointers"])
    end)
  end

  test "two boots against the same store append exactly ONE seed claim", ctx do
    boot!(ctx)
    assert [{first_id, first_claims}] = seed_claims()
    assert first_claims.timestamp == @oracle_seed_ts
    assert length(logged_seed_lines(ctx)) == 1

    Daemon.stop()
    boot!(ctx)

    # the second boot found its own live claim and appended nothing — the
    # log line count is what proves the skip, not the deduping set
    assert [{^first_id, _claims}] = seed_claims()
    assert length(logged_seed_lines(ctx)) == 1
  end

  test "a live seed claim by ANOTHER author does not satisfy the boot flag", ctx do
    foreign = signed_wire(@foreign_seed, [@oracle_pointer], @oracle_seed_ts)
    assert :ok = DurableStore.append(foreign)

    boot!(ctx)

    claims_by_id = Map.new(seed_claims())
    assert map_size(claims_by_id) == 2
    assert [own_id] = Map.keys(claims_by_id) -- [foreign["id"]]

    # the daemon appended its OWN claim: a foreign key's claim is one it
    # cannot keep alive, so the gate would rest on a claim it does not sign
    assert claims_by_id[own_id].author == Keys.author_for_seed(ctx.agent_seed)
    refute negated?(own_id)
  end

  test "a mint whose derived id is already negated steps to a fresh one", ctx do
    # merge-is-union: a negation can land BEFORE the claim it retracts, so
    # the fixed-ts boot id can be dead with no seed claim in the store at all
    negate!(ctx.agent_seed, seed_wire_id(ctx.agent_seed, @oracle_seed_ts))

    boot!(ctx)

    assert [{id, claims}] = seed_claims()
    assert claims.timestamp == @oracle_seed_ts + 1
    assert id == seed_wire_id(ctx.agent_seed, @oracle_seed_ts + 1)
    refute negated?(id)
  end

  test "a pre-negated fixed-ts ladder cannot pin the gate shut", ctx do
    # the attack: @oracle_seed_ts is a constant, so every id the fixed-ts
    # ladder can derive is pre-computable. A federation peer appends all
    # eleven negations BEFORE this daemon has ever booted.
    for bump <- 0..10,
        do: negate!(ctx.agent_seed, seed_wire_id(ctx.agent_seed, @oracle_seed_ts + bump))

    boot!(ctx)

    # the now_ts ladder mints an id the attacker could not predict, and it
    # is LIVE — the gate the boot reported open really is open
    assert [{id, claims}] = seed_claims()
    assert claims.timestamp > @oracle_seed_ts + 10
    refute negated?(id)
  end

  test "the now_ts ladder's nonce makes its ids unpredictable", ctx do
    # every OTHER field of the claim is public, so without the nonce a peer
    # could enumerate a millisecond window's ids and negate the lot. Two
    # mints from the same base must not collide.
    for bump <- 0..10,
        do: negate!(ctx.agent_seed, seed_wire_id(ctx.agent_seed, @oracle_seed_ts + bump))

    boot!(ctx)
    assert [{first_id, first_claims}] = seed_claims()

    negate!(ctx.agent_seed, first_id)
    Daemon.stop()
    boot!(ctx)

    claims_by_id = Map.new(seed_claims())
    assert [second_id] = Map.keys(claims_by_id) -- [first_id]
    second_claims = claims_by_id[second_id]

    # distinct ids even where the base ts collides — the nonce is what
    # separates them
    assert second_id != first_id
    assert nonce_of(first_claims) != nonce_of(second_claims)

    # the seed pointer stays at the HEAD: the reactor derives the claim's
    # kind from the first pointer's role, so a nonce in front would make the
    # gate unreadable
    assert [%{role: "seed"}, %{role: "nonce"}] = second_claims.pointers
    refute negated?(second_id)
  end

  test "the postcondition confirms THE MINTED claim, not any live seed-ish one", ctx do
    boot!(ctx)
    assert [{minted_id, _claims}] = seed_claims()
    assert Daemon.confirm_oracle_gate(minted_id) == :ok

    decoy =
      signed_wire(
        ctx.agent_seed,
        [%{role: "seed", target: {:entity, "garden", "seed"}}],
        1_754_700_000_000.0
      )

    assert :ok = DurableStore.append(decoy)

    # the decoy IS a gate claim — the reactor reads any live claim whose
    # first pointer has role "seed" — but it is not the mint, and the
    # postcondition asks only about the mint
    assert Daemon.confirm_oracle_gate(decoy["id"]) == :ok
    assert Daemon.confirm_oracle_gate(minted_id) == :ok

    # a negation racing the append leaves the mint dead on arrival. The
    # decoy is still live, so a read that asked only "is SOME gate claim
    # unretracted" would report this mint landed
    negate!(@operator_seed, minted_id)
    assert Daemon.confirm_oracle_gate(minted_id) == {:error, :gate_closed}
    assert gate_open?()
  end

  test "a ladder whose every id is negated refuses rather than minting a dead claim", ctx do
    # not reachable through a boot — the nonce mint behind this ladder is
    # always available — so the refusal is exercised directly, with a
    # negated set covering the whole ladder for one base
    base = 1_754_900_000_000.0
    state = %{author: Keys.author_for_seed(ctx.agent_seed), seed: ctx.agent_seed}
    negated = MapSet.new(for bump <- 0..10, do: seed_wire_id(ctx.agent_seed, base + bump))

    assert {:error, :negated_seed_id} = Daemon.seed_ladder(state, base, negated)
    assert {:ok, wire} = Daemon.seed_ladder(state, base + 11, negated)
    assert wire["claims"]["timestamp"] == base + 11
  end

  test "a retracted seed re-opens the gate with a NEW claim at a fresh ts", ctx do
    boot!(ctx)
    assert [{retracted_id, _claims}] = seed_claims()

    neg =
      signed_wire(
        ctx.agent_seed,
        [%{role: "negates", target: {:delta, retracted_id, "retracted"}}],
        1_754_600_000_000.0
      )

    assert :ok = DurableStore.append(neg)

    Daemon.stop()
    boot!(ctx)

    # the fixed-content id is taken by the retracted claim, so the re-assert
    # mints a distinct one at a fresh ts
    claims_by_id = Map.new(seed_claims())
    assert map_size(claims_by_id) == 2
    assert [live_id] = Map.keys(claims_by_id) -- [retracted_id]
    assert claims_by_id[live_id].timestamp != @oracle_seed_ts

    refute Enum.any?(DurableStore.set(), fn {_id, {claims, _sig}} ->
             Enum.any?(
               claims.pointers,
               &match?(%{role: "negates", target: {:delta, ^live_id, _ctx}}, &1)
             )
           end)

    # the gate is open: model initiation proceeds instead of refusing
    {:ok, signed} =
      Events.message_received(
        @human_seed,
        1_754_600_100_000,
        "message:t19os:reopen",
        "channel:reactor",
        "session:reactor",
        "gate reopened"
      )

    wire = Wire.envelope(signed)
    received_id = wire["id"]
    assert :ok = DurableStore.append(wire)
    assert_receive {:reactor, {:dispatch, "received", ^received_id}}, 2_000

    assert poll_store(fn {_id, {claims, _sig}} ->
             match?(
               [%{role: "promptRef", target: {:delta, ^received_id, "requested"}} | _rest],
               claims.pointers
             )
           end)
  end

  test "a config hot-swap re-opens a retracted gate through the same mint (D6)", ctx do
    boot_agent!(ctx)
    assert [{retracted_id, _claims}] = seed_claims()

    negate!(@operator_seed, retracted_id)

    # the flip reads the daemon's CACHE, so the negation has to have reached
    # it before the AgentSet does — otherwise the hot path still sees a live
    # seed and correctly appends nothing
    assert eventually(fn -> MapSet.member?(:sys.get_state(Daemon).negated_ids, retracted_id) end)

    append_set!(1_754_600_200_000.0, %{oracle_seed: "present"})

    assert eventually(fn ->
             Enum.any?(seed_claims(), fn {id, _claims} ->
               id != retracted_id and not negated?(id)
             end)
           end)

    # the fold's flip minted a NEW claim rather than resurrecting the
    # retracted content id, and the daemon's cache agrees the gate is open
    claims_by_id = Map.new(seed_claims())
    assert map_size(claims_by_id) == 2
    assert [live_id] = Map.keys(claims_by_id) -- [retracted_id]
    assert claims_by_id[live_id].author == Keys.author_for_seed(ctx.agent_seed)

    # the stepped fixed ts, not a now_ts: the flip runs the boot assert's
    # ladder, so the same determinism holds on both paths
    assert claims_by_id[live_id].timestamp == @oracle_seed_ts + 1

    daemon = :sys.get_state(Daemon)
    assert MapSet.member?(daemon.seed_ids, live_id)
    refute MapSet.member?(daemon.negated_ids, live_id)
  end

  test "closing the gate negates EVERY live seed claim, not just one (D6)", ctx do
    # since the boot skip is author-scoped, a store legitimately carries
    # more than one live seed claim — a foreign one and this daemon's own.
    # Negating one of them leaves the reactor's gate open while the operator
    # has been told it is closed.
    foreign = signed_wire(@foreign_seed, [@oracle_pointer], @oracle_seed_ts)
    assert :ok = DurableStore.append(foreign)

    boot_agent!(ctx)

    live_before = for {id, _claims} <- seed_claims(), not negated?(id), do: id
    assert length(live_before) == 2
    assert foreign["id"] in live_before

    append_set!(1_754_600_300_000.0, %{oracle_seed: "absent"})

    # the gate the REACTOR reads is what has to be shut, not a count of
    # negations: every live claim must be retracted
    assert eventually(fn -> Enum.all?(live_before, &negated?/1) end)
    assert Enum.all?(seed_claims(), fn {id, _claims} -> negated?(id) end)
    refute gate_open?()

    daemon = :sys.get_state(Daemon)
    assert Enum.all?(live_before, &MapSet.member?(daemon.negated_ids, &1))
  end

  test "closing the gate negates a live seed claim at ANY target (D6)", ctx do
    # the daemon's close path reads the gate the way the REACTOR does: a
    # claim whose FIRST pointer has role "seed" opens the gate whatever its
    # target. A close scoped to the exact oracle pointer would leave this one
    # alive — model initiation still authorized after the operator was told
    # the gate is closed.
    decoy =
      signed_wire(
        @foreign_seed,
        [%{role: "seed", target: {:entity, "garden", "seed"}}],
        1_754_700_000_000.0
      )

    assert :ok = DurableStore.append(decoy)

    boot_agent!(ctx)
    assert gate_open?()

    append_set!(1_754_600_500_000.0, %{oracle_seed: "absent"})

    assert eventually(fn -> not gate_open?() end)
    assert negated?(decoy["id"])
  end

  test "status carries the gate-flip failure counter, zero on a clean boot", ctx do
    boot!(ctx)
    assert Daemon.status().gate_flip_failures == 0

    Daemon.stop()
    boot_agent!(ctx)
    assert Daemon.status().gate_flip_failures == 0
  end

  test "a gate flip this daemon cannot honor logs and counts" do
    # the failure branches need a refused append or a negation racing the
    # mint, so the increment is exercised directly — a state that has never
    # failed a flip counts from zero either way
    log =
      capture_log(fn ->
        assert %{gate_flip_failures: 1} =
                 Daemon.note_gate_flip_failure(
                   %{narrate: false, gate_flip_failures: 0},
                   "oracle gate close FAILED — gate still open"
                 )

        assert %{gate_flip_failures: 1} =
                 Daemon.note_gate_flip_failure(%{narrate: false}, "oracle gate open refused")
      end)

    assert log =~ "oracle gate close FAILED"
    assert log =~ "oracle gate open refused"
  end

  test "the D6 open path is author-scoped like the boot assert", ctx do
    # a foreign live claim must not satisfy a fold that asks for :present —
    # the daemon would be running on a claim it cannot keep alive
    foreign = signed_wire(@foreign_seed, [@oracle_pointer], @oracle_seed_ts)
    assert :ok = DurableStore.append(foreign)

    boot_agent!(ctx)
    own_author = Keys.author_for_seed(ctx.agent_seed)

    # retract the boot's OWN claim, so the only thing left alive is the
    # foreign one — an author-blind hot path reads that as "gate open" and
    # appends nothing
    claims_by_id = Map.new(seed_claims())
    assert [boot_id] = Map.keys(claims_by_id) -- [foreign["id"]]
    assert claims_by_id[boot_id].author == own_author

    negate!(@operator_seed, boot_id)
    assert eventually(fn -> MapSet.member?(:sys.get_state(Daemon).negated_ids, boot_id) end)
    refute negated?(foreign["id"])

    append_set!(1_754_600_400_000.0, %{oracle_seed: "present"})

    # the fold mints a claim THIS daemon signs, distinct from both
    assert eventually(fn ->
             Enum.any?(seed_claims(), fn {id, claims} ->
               id not in [boot_id, foreign["id"]] and claims.author == own_author and
                 not negated?(id)
             end)
           end)
  end

  test "a seed retracted by a claim's SECOND negates pointer is closed for the reactor too",
       ctx do
    boot!(ctx)
    assert [{seed_id, _claims}] = seed_claims()

    # both reads agree the gate is OPEN: the daemon minted a live seed and
    # the reactor initiates on it
    open_id = received!("message:t19os:agree-open", "gate agrees open", 1_754_610_000_000)
    assert_receive {:reactor, {:dispatch, "received", ^open_id}}, 2_000
    assert poll_store(&prompt_ref?(&1, open_id))

    # the retraction a first-pointer-only read misses: TWO negates pointers,
    # the seed at the SECOND. The daemon's close path honours every pointer,
    # so a reactor that read only the first would keep initiating after the
    # operator was told the gate was shut.
    unrelated = seed_wire_id(ctx.agent_seed, 1_754_620_000_000.0)

    two_negates =
      signed_wire(
        @operator_seed,
        [
          %{role: "negates", target: {:delta, unrelated, "retracted"}},
          %{role: "negates", target: {:delta, seed_id, "retracted"}}
        ],
        1_754_630_000_000.0
      )

    assert :ok = DurableStore.append(two_negates)
    assert negated?(seed_id)
    refute gate_open?()

    closed_id = received!("message:t19os:agree-shut", "gate agrees shut", 1_754_640_000_000)
    assert_receive {:reactor, {:dispatch, "received", ^closed_id}}, 2_000

    assert %{type: "GateDecision", verdict: "refuse", policy: "oracle_gate"} =
             refusal_for(closed_id)

    refute Enum.any?(DurableStore.set(), &prompt_ref?(&1, closed_id))
  end

  test "the single-negates retraction agrees the same way", ctx do
    boot!(ctx)
    assert [{seed_id, _claims}] = seed_claims()

    negate!(@operator_seed, seed_id)
    assert negated?(seed_id)
    refute gate_open?()

    received_id = received!("message:t19os:single", "one negates pointer", 1_754_650_000_000)
    assert_receive {:reactor, {:dispatch, "received", ^received_id}}, 2_000

    assert %{type: "GateDecision", verdict: "refuse", policy: "oracle_gate"} =
             refusal_for(received_id)
  end

  test "a boot whose seed append FAILS still boots, counts, and refuses", ctx do
    # the real failure, not the counter helper: the log file is read-only, so
    # the store's lazy open refuses and the mint never lands
    break_appends!(ctx)

    log = capture_log(fn -> boot!(ctx) end)

    assert log =~ "NO live seed claim exists"
    assert log =~ "refuse-only"
    assert Daemon.status().gate_flip_failures == 1
    assert seed_claims() == []

    restore_appends!(ctx)

    # the posture the message promised: model initiation refuses
    received_id = received!("message:t19os:failsoft", "no gate", 1_754_660_000_000)
    assert_receive {:reactor, {:dispatch, "received", ^received_id}}, 2_000

    assert %{type: "GateDecision", verdict: "refuse", policy: "oracle_gate"} =
             refusal_for(received_id)
  end

  test "a failed mint over a FOREIGN live seed says the gate is open, not refuse-only", ctx do
    foreign = signed_wire(@foreign_seed, [@oracle_pointer], @oracle_seed_ts)
    assert :ok = DurableStore.append(foreign)

    break_appends!(ctx)

    log = capture_log(fn -> boot!(ctx) end)

    # the daemon has no claim of its own, but the reactor's gate is OPEN on
    # the foreign one — "refuse-only" would be a lie in exactly the case
    # where model initiation still proceeds
    assert log =~ "NOT opened by THIS daemon"
    assert log =~ "foreign claim this daemon cannot retract or keep alive"
    refute log =~ "boots refuse-only"
    assert Daemon.status().gate_flip_failures == 1

    restore_appends!(ctx)

    received_id = received!("message:t19os:foreign-open", "foreign gate", 1_754_670_000_000)
    assert_receive {:reactor, {:dispatch, "received", ^received_id}}, 2_000
    assert poll_store(&prompt_ref?(&1, received_id))
  end

  test "a close whose negations cannot land reports the gate STILL OPEN", ctx do
    foreign = signed_wire(@foreign_seed, [@oracle_pointer], @oracle_seed_ts)
    assert :ok = DurableStore.append(foreign)

    # the fold delta is appended BEFORE the appends are broken and replayed
    # into the daemon by hand: the feed's own delivery would race the chmod
    set_id = append_set!(1_754_600_600_000.0, %{oracle_seed: "absent"})
    {set_claims, _sig} = Map.fetch!(DurableStore.set(), set_id)

    boot_agent!(ctx)
    live_before = for {id, _claims} <- seed_claims(), not negated?(id), do: id
    assert length(live_before) == 2

    break_appends!(ctx)

    log =
      capture_log(fn ->
        # the same message the store's fan-out sends, for a delta that IS in
        # the store; the call behind it is the barrier (the daemon's loop is
        # serialized, so a reply means the fold ahead of it has run)
        send(Daemon, {:delta, set_id, set_claims})
        assert %{} = Daemon.status()
      end)

    assert log =~ "oracle gate close refused"
    assert log =~ "gate still open"
    assert Daemon.status().gate_flip_failures >= 1

    # the daemon survived and the store still tells the truth: nothing was
    # retracted, so the gate the reactor reads is the gate the log describes
    assert Process.alive?(Process.whereis(Daemon))
    assert Enum.all?(live_before, fn id -> not negated?(id) end)
    assert gate_open?()

    restore_appends!(ctx)
  end

  test "a repeated absent fold re-negates nothing, and names each foreign author", ctx do
    foreign = signed_wire(@foreign_seed, [@oracle_pointer], @oracle_seed_ts)
    assert :ok = DurableStore.append(foreign)

    boot_agent!(ctx)
    live_before = for {id, _claims} <- seed_claims(), not negated?(id), do: id
    assert length(live_before) == 2

    log =
      capture_log(fn ->
        append_set!(1_754_600_700_000.0, %{oracle_seed: "absent"})
        assert eventually(fn -> Enum.all?(live_before, &negated?/1) end)
      end)

    # the foreign retraction is attributed: a close that walks over another
    # principal's claims is visible without the operator having opted into
    # narration
    assert log =~ "retracting foreign seed claim #{String.slice(foreign["id"], 0, 8)}"
    assert log =~ "author #{Keys.author_for_seed(@foreign_seed)}"

    # exactly ONE negation per live claim, and a SECOND absent fold adds none:
    # a re-fold against an already-closed gate must not re-negate a federated
    # peer's claim on every pass
    assert Enum.all?(live_before, fn id -> logged_negations_for(ctx, id) == 1 end)

    folds = :sys.get_state(Daemon).folds_since_boot
    append_set!(1_754_600_800_000.0, %{oracle_seed: "absent"})
    assert eventually(fn -> :sys.get_state(Daemon).folds_since_boot > folds end)

    assert Enum.all?(live_before, fn id -> logged_negations_for(ctx, id) == 1 end)
  end

  # a REAL append refusal, not a stubbed one: the store opens the log lazily
  # and caches the io handle, so the handle is dropped (and closed) first and
  # write permission is taken off the file — the next append re-opens into
  # :eacces. The DIRECTORY stays writable: the daemon's boot lock lives there,
  # and a read-only dir would refuse the boot for an unrelated reason.
  defp break_appends!(ctx) do
    :sys.replace_state(DurableStore, fn state ->
      if is_pid(state.io), do: File.close(state.io)
      %{state | io: nil}
    end)

    File.touch!(ctx.log_path)
    File.chmod!(ctx.log_path, 0o444)
    on_exit(fn -> File.chmod(ctx.log_path, 0o644) end)
  end

  defp restore_appends!(ctx), do: File.chmod!(ctx.log_path, 0o644)

  defp received!(message_id, body, ts) do
    {:ok, signed} =
      Events.message_received(
        @human_seed,
        ts,
        message_id,
        "channel:reactor",
        "session:reactor",
        body
      )

    wire = Wire.envelope(signed)
    assert :ok = DurableStore.append(wire)
    wire["id"]
  end

  defp prompt_ref?({_id, {claims, _sig}}, received_id) do
    match?(
      [%{role: "promptRef", target: {:delta, ^received_id, "requested"}} | _rest],
      claims.pointers
    )
  end

  defp refusal_for(received_id) do
    case poll_store(&refusal?(&1, received_id)) do
      {_id, {claims, _sig}} -> Schema.resolve(claims)
      nil -> nil
    end
  end

  defp refusal?({_id, {claims, _sig}}, received_id) do
    match?([%{role: "decides"} | _rest], claims.pointers) and
      Schema.resolve(claims).decides == {:delta, received_id, "decided"}
  end

  # the LOG, not the set: a re-negation at a fresh timestamp is a DISTINCT
  # content id, so the deduping set cannot tell one close from two
  defp logged_negations_for(ctx, target) do
    ctx.log_path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.count(fn line ->
      {:ok, wire} = Wire.decode(line)

      Enum.any?(wire["claims"]["pointers"], fn pointer ->
        pointer["role"] == "negates" and pointer["target"]["delta"] == target
      end)
    end)
  end

  # the reactor's own gate read (pin 16): any unretracted claim whose first
  # pointer has role "seed" — the thing an operator is told is "closed"
  defp gate_open? do
    Enum.any?(DurableStore.set(), fn {id, {claims, _sig}} ->
      match?([%{role: "seed"} | _rest], claims.pointers) and not negated?(id)
    end)
  end

  defp nonce_of(claims) do
    Enum.find_value(claims.pointers, fn
      %{role: "nonce", target: {:entity, _id, nonce}} -> nonce
      _other -> nil
    end)
  end

  # bounded sleep-free polling on a condition, no Process.sleep: a
  # timeout-only receive matches nothing, so it consumes no mailbox message
  defp eventually(fun, attempts \\ 200) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if fun.() do
        {:halt, true}
      else
        receive do
        after
          25 -> :timeout
        end

        {:cont, false}
      end
    end)
  end

  # bounded sleep-free store polling: a timeout-only receive never matches
  # mailbox messages, so it cannot swallow reactor probes
  defp poll_store(pred, attempts \\ 200) do
    Enum.reduce_while(1..attempts, nil, fn _, _ ->
      case Enum.find(DurableStore.set(), pred) do
        nil ->
          receive do
          after
            25 -> :timeout
          end

          {:cont, nil}

        found ->
          {:halt, found}
      end
    end)
  end
end
