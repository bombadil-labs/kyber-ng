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
  reactor too) and pins the boot narration's honesty: a boot that could not
  mint says which of the two it is — refuse-only, or open on someone else's
  claim.

  Round 9 draws the daemon's blast radius at its own signature. The close
  retracts every live seed claim this daemon SIGNED and refuses the rest
  loudly (a config fold on one agent does not write permanent negations
  against another principal's deltas, so the gate stays open and status says
  so); the boot attestation anchors to this daemon's own oracle mint rather
  than to whichever live seed claim a map walk reached first; an unwritable
  store REFUSES the boot while a hostile peer's negations still cannot deny
  startup; and a flip that cannot be honored is latched, so a standing fold
  refuses once rather than on every later AgentSet.

  Round 10 splits the flip latch by FAILURE CLASS. A latch inferred from the
  failure counter treats a refused store write like a permanent refusal, so
  one disk blip during an `absent` fold left the gate — the control that
  authorizes model spend — standing OPEN against an explicit operator close,
  with the standing fold skipping the flip on every pass and nothing ever
  retrying. Transient store I/O now never latches; foreign claims holding the
  gate open still do.

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
  defp boot_agent!(ctx, extra \\ []) do
    opts =
      Keyword.merge(
        [
          keyring_dir: ctx.keyring_dir,
          tick_ms: :manual,
          loop: :reactor,
          oracle_seed: :present,
          agent: "mokosh",
          operator_seed: @operator_seed,
          budget_cap: 32,
          test_pid: self()
        ],
        extra
      )

    assert {:ok, _pid} = Daemon.boot(opts)
  end

  defp attestations do
    Enum.filter(DurableStore.set(), fn {_id, {claims, _sig}} ->
      match?(%{type: "BootAttestation"}, Schema.resolve(claims))
    end)
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
    #
    # This is the HOSTILE-NEGATION class, and it must never deny startup —
    # the other class, an unwritable store, refuses (see the boot-refusal
    # test below).
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

  test "closing the gate negates EVERY live seed claim THIS DAEMON SIGNED (D6)", ctx do
    # a store legitimately carries more than one of this daemon's own live
    # seed claims. Negating one of them leaves the reactor's gate open while
    # the operator has been told it is closed.
    boot_agent!(ctx)
    assert [{boot_id, _claims}] = seed_claims()

    # appended AFTER the boot: an own live claim already in the store would
    # satisfy the author-scoped boot skip, and nothing would be minted
    second_own = signed_wire(ctx.agent_seed, [@oracle_pointer], @oracle_seed_ts + 5)
    assert :ok = DurableStore.append(second_own)
    assert eventually(fn -> MapSet.member?(:sys.get_state(Daemon).seed_ids, second_own["id"]) end)

    live_before = for {id, _claims} <- seed_claims(), not negated?(id), do: id
    assert Enum.sort(live_before) == Enum.sort([boot_id, second_own["id"]])

    append_set!(1_754_600_300_000.0, %{oracle_seed: "absent"})

    # the gate the REACTOR reads is what has to be shut, not a count of
    # negations: every live claim of ours must be retracted
    assert eventually(fn -> Enum.all?(live_before, &negated?/1) end)
    refute gate_open?()

    daemon = :sys.get_state(Daemon)
    assert Enum.all?(live_before, &MapSet.member?(daemon.negated_ids, &1))
    assert Daemon.status().foreign_gate_claims_open == 0
  end

  test "a close retracts what this daemon SIGNED and REFUSES the rest (D6)", ctx do
    # `oracle_seed: "absent"` is a config fold on ONE agent. Honoring it
    # store-wide would write permanent negations against another principal's
    # deltas — including the anchor another agent's boot attestation points
    # at — which is not a side effect a single daemon's config fold owns.
    foreign = signed_wire(@foreign_seed, [@oracle_pointer], @oracle_seed_ts)
    assert :ok = DurableStore.append(foreign)

    boot_agent!(ctx)

    live_before = for {id, _claims} <- seed_claims(), not negated?(id), do: id
    assert length(live_before) == 2
    assert [own_id] = live_before -- [foreign["id"]]

    log =
      capture_log(fn ->
        append_set!(1_754_600_300_000.0, %{oracle_seed: "absent"})
        assert eventually(fn -> Daemon.status().foreign_gate_claims_open == 1 end)
      end)

    assert negated?(own_id)
    refute negated?(foreign["id"])

    # the gate is therefore STILL OPEN, and every channel says so rather than
    # reporting a close that did not fully happen
    assert gate_open?()
    assert Daemon.status().gate_flip_failures >= 1
    assert log =~ "oracle gate STILL OPEN on 1 foreign seed claim(s)"

    # the claim holding it open is named, with its author in full, so the
    # operator knows whose agent to go ask
    assert log =~ "close REFUSED for foreign seed claim #{String.slice(foreign["id"], 0, 8)}"
    assert log =~ "author #{Keys.author_for_seed(@foreign_seed)}"
  end

  test "closing the gate negates a live seed claim at ANY target (D6)", ctx do
    # the daemon's close path reads the gate the way the REACTOR does: a
    # claim whose FIRST pointer has role "seed" opens the gate whatever its
    # target. A close scoped to the exact oracle pointer would leave this one
    # alive — model initiation still authorized after the operator was told
    # the gate is closed. The close's own scope is the SIGNING AUTHOR, so a
    # decoy of ours at another target is ours to retract.
    decoy =
      signed_wire(
        ctx.agent_seed,
        [%{role: "seed", target: {:entity, "garden", "seed"}}],
        1_754_700_000_000.0
      )

    assert :ok = DurableStore.append(decoy)

    boot_agent!(ctx)
    assert gate_open?()

    append_set!(1_754_600_500_000.0, %{oracle_seed: "absent"})

    assert eventually(fn -> not gate_open?() end)
    assert negated?(decoy["id"])
    assert Daemon.status().foreign_gate_claims_open == 0
  end

  test "the boot attestation anchors to THIS daemon's OWN oracle mint", ctx do
    # the operator attestation's `boot` pointer says "the operator attested
    # THIS daemon's boot". A store holds several live seed claims — a
    # federated peer's, and a decoy of ours leading with a "seed" role at
    # another target — and an any-live read picks one arbitrarily, so the
    # attestation can end up pointing at a mint this daemon never signed.
    foreign = signed_wire(@foreign_seed, [@oracle_pointer], @oracle_seed_ts)
    assert :ok = DurableStore.append(foreign)

    decoy =
      signed_wire(
        ctx.agent_seed,
        [%{role: "seed", target: {:entity, "garden", "seed"}}],
        1_754_700_000_000.0
      )

    assert :ok = DurableStore.append(decoy)

    boot_agent!(ctx)

    own_author = Keys.author_for_seed(ctx.agent_seed)

    assert [{own_id, _claims}] =
             Enum.filter(seed_claims(), fn {_id, claims} ->
               claims.author == own_author and Enum.member?(claims.pointers, @oracle_pointer)
             end)

    assert [{_att_id, {att_claims, _sig}}] = attestations()
    att = Schema.resolve(att_claims)
    assert att.agent == {:entity, own_author, "attested"}
    assert att.boot == {:delta, own_id, "booted_under"}
  end

  test "a boot with only a FOREIGN live seed claim emits NO attestation", ctx do
    foreign = signed_wire(@foreign_seed, [@oracle_pointer], @oracle_seed_ts)
    assert :ok = DurableStore.append(foreign)

    # :absent, so this daemon mints nothing — the only live seed claim is one
    # it did not sign, and there is nothing of its own to attest to. Skipping
    # is the same posture the rest of the attestation path takes.
    boot_agent!(ctx, oracle_seed: :absent)

    assert Enum.map(seed_claims(), &elem(&1, 0)) == [foreign["id"]]
    assert attestations() == []
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

  test "an UNWRITABLE store REFUSES the boot rather than booting silently", ctx do
    # the OTHER failure class. A peer pre-negating ids must not deny startup
    # (the fixed-ts ladder test above), but a store that will not take a
    # write is not a gate problem at all: the daemon can record NOTHING —
    # no refusal, no checkpoint, no attestation — so a successful boot here
    # would report a running agent that is silently writing nothing.
    unwritable_store!(ctx)

    assert {:error, {:oracle_seed, :persist_failed}} = boot(ctx)
    refute Process.whereis(Daemon)
  end

  test "an unwritable store is inert for a boot that never asks for the gate", ctx do
    # the refusal belongs to the seed assert, not to boot at large: an
    # :absent boot writes no seed claim and is left exactly as it was
    unwritable_store!(ctx)

    assert {:ok, _pid} =
             Daemon.boot(
               keyring_dir: ctx.keyring_dir,
               tick_ms: :manual,
               loop: :reactor,
               oracle_seed: :absent,
               budget_cap: 32,
               test_pid: self()
             )
  end

  test "a failed mint over a FOREIGN live seed says the gate is open, not refuse-only", _ctx do
    foreign = signed_wire(@foreign_seed, [@oracle_pointer], @oracle_seed_ts)
    assert :ok = DurableStore.append(foreign)

    # the narration reads the ACTUAL store, so the store is the fixture and
    # the refusal reason is the seam — reaching this through a real boot now
    # needs a negation racing the append
    log =
      capture_log(fn ->
        assert %{gate_flip_failures: 1} =
                 Daemon.warn_gate_not_opened(%{narrate: false}, :gate_closed)
      end)

    # the daemon has no claim of its own, but the reactor's gate is OPEN on
    # the foreign one — "refuse-only" would be a lie in exactly the case
    # where model initiation still proceeds
    assert log =~ "NOT opened by THIS daemon"
    assert log =~ "foreign claim this daemon cannot retract or keep alive"
    refute log =~ "boots refuse-only"
  end

  test "a failed mint with NO live seed says the daemon boots refuse-only", _ctx do
    assert seed_claims() == []

    log =
      capture_log(fn ->
        assert %{gate_flip_failures: 1} =
                 Daemon.warn_gate_not_opened(%{narrate: false}, :gate_closed)
      end)

    assert log =~ "NO live seed claim exists"
    assert log =~ "boots refuse-only"
    refute log =~ "NOT opened by THIS daemon"
  end

  test "a close it cannot honor is refused ONCE across folds, and re-arms", ctx do
    foreign = signed_wire(@foreign_seed, [@oracle_pointer], @oracle_seed_ts)
    assert :ok = DurableStore.append(foreign)

    boot_agent!(ctx)
    live_before = for {id, _claims} <- seed_claims(), not negated?(id), do: id
    assert [own_id] = live_before -- [foreign["id"]]

    first =
      capture_log(fn ->
        append_set!(1_754_600_700_000.0, %{oracle_seed: "absent"})
        assert eventually(fn -> Daemon.status().foreign_gate_claims_open == 1 end)
      end)

    assert refusals_in(first) == 1
    failures = Daemon.status().gate_flip_failures

    # foreign claims holding the gate open is the PERMANENT class: this daemon
    # does not retract what it did not sign, so no later fold has anything new
    # to try. That — and only that — is what latches.
    assert :sys.get_state(Daemon).gate_flip_latch == :absent

    # `oracle_seed` STANDS in the folded view, so every later AgentSet on this
    # agent — about anything at all — re-enters the flip path. Without the
    # latch each one re-scans the store and re-logs the same refusal.
    second =
      capture_log(fn ->
        fold!(1_754_600_800_000.0, %{system_prompt: "a standing unrelated fold"})
        fold!(1_754_600_900_000.0, %{oracle_seed: "absent"})
      end)

    assert refusals_in(second) == 0
    assert Daemon.status().gate_flip_failures == failures

    # exactly ONE negation against our own claim across all of it — a re-fold
    # must not re-negate on every pass
    assert logged_negations_for(ctx, own_id) == 1

    # a gate-relevant delta from ANOTHER principal re-arms the flip: the
    # answer it latched can have changed
    third =
      capture_log(fn ->
        second_foreign = signed_wire(@foreign_seed, [@oracle_pointer], @oracle_seed_ts + 3)
        assert :ok = DurableStore.append(second_foreign)
        assert eventually(fn -> :sys.get_state(Daemon).gate_flip_latch == nil end)

        fold!(1_754_601_000_000.0, %{oracle_seed: "absent"})
      end)

    assert refusals_in(third) == 1
    assert third =~ "STILL OPEN on 2 foreign seed claim(s)"
    assert Daemon.status().foreign_gate_claims_open == 2
  end

  test "a TRANSIENT store failure on a close does NOT latch — the next fold retries", ctx do
    # the round-9 latch read "unhonorable" off the failure counter, so ONE
    # refused write during an `absent` fold latched :absent — and the fold is
    # STANDING, so every later fold skipped the flip and the gate that
    # authorizes model spend stayed OPEN against an explicit operator close,
    # forever, with nothing ever retrying.
    own = signed_wire(ctx.agent_seed, [@oracle_pointer], @oracle_seed_ts)
    assert :ok = DurableStore.append(own)
    {set_wire, set_claims} = set_delta(1_754_601_100_000.0, %{oracle_seed: "absent"})
    assert :ok = DurableStore.append(set_wire)

    heal = flaky_store!(ctx)

    # :absent at boot, so the boot mints nothing — the live seed claim is the
    # one replayed above, and it is THIS daemon's own
    boot_agent!(ctx, oracle_seed: :absent)
    assert gate_open?()
    assert MapSet.member?(:sys.get_state(Daemon).own_seed_ids, own["id"])

    log =
      capture_log(fn ->
        refold!(set_wire, set_claims)
      end)

    # the negation could not land, so the gate is still open and every channel
    # says so
    assert log =~ "close FAILED — gate still open on this daemon's OWN seed claim(s)"
    assert Daemon.status().gate_flip_failures >= 1
    refute negated?(own["id"])
    assert gate_open?()

    # ...and the flip did NOT latch: the claims are still ours to retract and
    # the store may take the write next time
    assert :sys.get_state(Daemon).gate_flip_latch == nil

    heal.()

    # the SAME standing `absent` fold, re-delivered: it retries the close and
    # lands it
    refold!(set_wire, set_claims)

    assert eventually(fn -> negated?(own["id"]) end)
    refute gate_open?()
    assert :sys.get_state(Daemon).gate_flip_latch == nil
  end

  test "a TRANSIENT store failure on an OPEN does NOT latch — the next fold retries", ctx do
    {set_wire, set_claims} = set_delta(1_754_601_200_000.0, %{oracle_seed: "present"})
    assert :ok = DurableStore.append(set_wire)

    heal = flaky_store!(ctx)

    # :absent at boot, so the store carries no seed claim at all — the fold's
    # `present` is what asks for the mint
    boot_agent!(ctx, oracle_seed: :absent)
    refute gate_open?()

    log = capture_log(fn -> refold!(set_wire, set_claims) end)

    assert log =~ "oracle gate open refused :persist_failed"
    assert Daemon.status().gate_flip_failures >= 1
    refute gate_open?()
    assert :sys.get_state(Daemon).gate_flip_latch == nil

    heal.()
    refold!(set_wire, set_claims)

    assert eventually(fn -> gate_open?() end)
    assert :sys.get_state(Daemon).gate_flip_latch == nil

    # the claim it finally minted is its OWN, exactly as the boot assert's
    # would have been
    assert [{_id, claims}] = seed_claims()
    assert claims.author == Keys.author_for_seed(ctx.agent_seed)
  end

  # an UNWRITABLE store, uid-independent (a chmod means nothing to root): the
  # log path is a symlink into a directory that does not exist, so the
  # store's lazy open fails :enoent for everyone. Replay is untouched — a
  # dangling link does not exist, and a first boot on a nonexistent log is
  # not an error — and the daemon's lock (`<log>.lock`) lands beside the LINK
  # in a real writable directory, so the boot reaches the seed assert.
  defp unwritable_store!(ctx) do
    Daemon.stop()
    stop_app()

    dir = Path.dirname(ctx.log_path)
    broken = Path.join(dir, "unwritable.jsonl")
    File.ln_s!(Path.join(dir, "gone/store.jsonl"), broken)

    Application.put_env(:kyber, :log_path, broken)
    assert {:ok, _} = Application.ensure_all_started(:kyber)
    broken
  end

  # a store whose appends fail TRANSIENTLY, uid-independent for the same
  # reason unwritable_store!/1 is: the log path is a SYMLINK the replay
  # follows to a real file, and the store opens the log LAZILY (on the first
  # append, never at boot). So the store replays the bytes, and removing the
  # link's target DIRECTORY afterwards makes every append fail
  # :persist_failed without ever touching a live handle; putting the
  # directory back makes the next append land — a disk blip, not a permanent
  # condition. The directory, not just the file: `Kyber.Log.open/1` opens
  # append+CREATE, so a merely-missing file is created through the link.
  #
  # Returns a zero-arg fun that heals the store.
  defp flaky_store!(ctx) do
    Daemon.stop()
    stop_app()

    dir = Path.dirname(ctx.log_path)
    live = Path.join(dir, "flaky-live")
    target = Path.join(live, "store.jsonl")
    link = Path.join(dir, "flaky.jsonl")
    replayed = File.read!(ctx.log_path)
    File.mkdir_p!(live)
    File.write!(target, replayed)
    File.ln_s!(target, link)

    Application.put_env(:kyber, :log_path, link)
    assert {:ok, _} = Application.ensure_all_started(:kyber)

    File.rm_rf!(live)

    fn ->
      File.mkdir_p!(live)
      File.write!(target, replayed)
    end
  end

  # the AgentSet as the FEED hands it over ({:delta, id, claims} — the
  # DurableStore fan-out contract), so a fold can be driven on a store that
  # cannot take a write. The delta itself is in the store from before the
  # break, which is what the re-fold's head check reads.
  defp set_delta(ts, fields) do
    {:ok, {claims, _sig} = signed} = AgentEvents.agent_set(@operator_seed, ts, "mokosh", fields)
    {Wire.envelope(signed), claims}
  end

  defp refold!(wire, claims) do
    folds = :sys.get_state(Daemon).folds_since_boot
    send(Daemon, {:delta, wire["id"], claims})
    assert eventually(fn -> :sys.get_state(Daemon).folds_since_boot > folds end)
  end

  # one fold, awaited: the daemon's loop is serialized, so a folds_since_boot
  # bump means the AgentSet ahead of it has been applied
  defp fold!(ts, fields) do
    folds = :sys.get_state(Daemon).folds_since_boot
    append_set!(ts, fields)
    assert eventually(fn -> :sys.get_state(Daemon).folds_since_boot > folds end)
  end

  defp refusals_in(log) do
    log
    |> String.split("\n")
    |> Enum.count(&(&1 =~ "oracle gate STILL OPEN on"))
  end

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
