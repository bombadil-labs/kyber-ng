defmodule Kyber.Agent.T17AgentCliTest do
  @moduledoc """
  T17 — the `kyber agent` verb: the operator's no-boot mutation surface over
  an agent's AgentSet store. Every verb opens the store file directly
  (Log.stream + Store.admit — never a second DurableStore on a live log),
  validates at the door (Config.validate_fields), appends operator-attested
  deltas, and folds with Config.resolve. Registry and stores are tmp-only;
  the operator seed rides an env NAME, never argv.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Kyber.{CLI, DeltaSet, Keys, Log, Schema, Store, Wire}
  alias Kyber.Agent.{Config, Secrets}
  alias Kyber.Agent.Events, as: AgentEvents

  @operator_seed String.duplicate("7f", 32)
  @new_seed String.duplicate("8e", 32)

  setup do
    uniq = "#{System.os_time()}-#{System.unique_integer([:positive])}"
    registry = Path.join(System.tmp_dir!(), "kyber-t17-registry-#{uniq}")
    File.mkdir_p!(registry)
    System.put_env("T17_OP_SEED", @operator_seed)
    System.put_env("DEEPSEEK_API_KEY", "test-key-not-real")

    on_exit(fn ->
      System.delete_env("T17_OP_SEED")
      System.delete_env("DEEPSEEK_API_KEY")
      System.delete_env("T17_NEW_SEED")
      System.delete_env("T17_OTHER_KEY")
      File.rm_rf(registry)
    end)

    {:ok, registry: registry}
  end

  defp agent(args, registry), do: CLI.run(["agent" | args] ++ ["--registry", registry])

  defp new!(registry, extra \\ []) do
    assert {:ok, _message} =
             agent(
               ["new", "wisp", "--soul", "I am wisp, the quiet sibling."] ++
                 ["--operator-seed-env", "T17_OP_SEED"] ++ extra,
               registry
             )
  end

  defp store_path(registry), do: Path.join([registry, "wisp", "store.jsonl"])

  defp load_set(registry) do
    store_path(registry)
    |> Log.stream()
    |> Enum.reduce(DeltaSet.new(), fn line, set ->
      {:ok, wire} = JSON.decode(line)
      {:ok, set} = Store.admit(wire, set)
      set
    end)
  end

  defp pointer!(registry),
    do: JSON.decode!(File.read!(Path.join([registry, "wisp", "agent.json"])))

  # the fold as consumers see it: PINNED to the pointer's operator chain
  # (resolve/2 is display-only legacy)
  defp fold!(registry) do
    {:ok, view} =
      Config.resolve(load_set(registry), "wisp", pointer!(registry)["operator_authors"])

    view
  end

  # a store-level append BYPASSING the CLI door — the attacker's move: a
  # held seed writes directly to the stream
  defp append_raw!(registry, seed, ts, fields) do
    {:ok, signed} = AgentEvents.agent_set(seed, ts, "wisp", fields)
    {:ok, io} = Log.open(store_path(registry))
    :ok = Log.append(io, Wire.envelope(signed))
    File.close(io)
  end

  defp store_lines(registry), do: store_path(registry) |> Log.stream() |> Enum.to_list()

  # P5 round-7 HIGH-1 (AC21): the operator seed VALUE never touches disk —
  # no human.seed file anywhere under the registry, and no file's bytes
  # contain any given seed
  defp assert_no_seed_on_disk!(registry, seeds) do
    files = registry |> Path.join("**") |> Path.wildcard(match_dot: true)
    assert Enum.filter(files, &(Path.basename(&1) == "human.seed")) == []

    for file <- files, File.regular?(file), seed <- seeds do
      refute File.read!(file) =~ seed, "seed VALUE serialized at #{file}"
    end
  end

  describe "agent new (AC1/AC14)" do
    test "creates the store, the pointer, the keyring, and the genesis + seed deltas", %{
      registry: registry
    } do
      assert {:ok, message} =
               agent(
                 ["new", "wisp", "--soul", "I am wisp.", "--operator-seed-env", "T17_OP_SEED"],
                 registry
               )

      assert message =~ "wisp"
      assert File.exists?(store_path(registry))

      # the registry pointer (recorded spec-contradiction resolution: the
      # pointer JSON lives INSIDE the agent dir, at <registry>/<name>/agent.json)
      pointer = Path.join([registry, "wisp", "agent.json"])

      assert {:ok, %{"log_path" => log_path, "keyring_dir" => keyring}} =
               JSON.decode(File.read!(pointer))

      assert log_path == store_path(registry)
      assert File.dir?(keyring)

      # P5 round-7 HIGH-1 (AC21): env-held, never serialized — the keyring
      # dir exists (the daemon mints agent.seed there at first boot) but the
      # operator seed VALUE is nowhere under the registry
      assert_no_seed_on_disk!(registry, [@operator_seed])

      # AC14: no provider flags given — the genesis layer carries deepseek
      view = fold!(registry)
      assert view.soul == "I am wisp."
      assert view.base_url == "https://api.deepseek.com/v1"
      assert view.model == "deepseek-v4-flash"
      assert view.api_key == {:env, "DEEPSEEK_API_KEY"}
      assert view.loop == "reactor"
      assert view.oracle_seed == "absent"
      assert view.self_config == false
      # the signing env NAME is recorded so later verbs can find the seed
      assert view.operator_seed_env == "T17_OP_SEED"

      # genesis first, seed second: two AgentSet deltas on disk
      agent_sets =
        for {_id, {claims, _sig}} <- load_set(registry),
            %{type: "AgentSet"} <- [Schema.resolve(claims)],
            do: claims

      assert length(agent_sets) == 2
    end

    test "refuses to overwrite an existing agent without --force", %{registry: registry} do
      new!(registry)
      assert {:error, message} = agent(["new", "wisp", "--soul", "x"], registry)
      assert message =~ "--force"

      assert {:ok, _} =
               agent(
                 [
                   "new",
                   "wisp",
                   "--soul",
                   "renewed",
                   "--force",
                   "--operator-seed-env",
                   "T17_OP_SEED"
                 ],
                 registry
               )

      assert fold!(registry).soul == "renewed"
    end

    test "an unresolvable operator seed env is a legible refusal, no store created", %{
      registry: registry
    } do
      System.delete_env("T17_OP_SEED")

      assert {:error, message} =
               agent(
                 ["new", "wisp", "--soul", "x", "--operator-seed-env", "T17_OP_SEED"],
                 registry
               )

      assert message =~ "T17_OP_SEED"
      refute File.exists?(store_path(registry))
    end

    test "a born-broken fallback is refused: the genesis key env must be present", %{
      registry: registry
    } do
      System.delete_env("DEEPSEEK_API_KEY")

      assert {:error, message} =
               agent(
                 ["new", "wisp", "--soul", "x", "--operator-seed-env", "T17_OP_SEED"],
                 registry
               )

      assert message =~ "DEEPSEEK_API_KEY"
      refute File.exists?(store_path(registry))
    end

    test "--api-key-env override is validated instead of the genesis name", %{registry: registry} do
      System.delete_env("DEEPSEEK_API_KEY")
      System.put_env("T17_OTHER_KEY", "also-not-real")

      new!(registry, ["--api-key-env", "T17_OTHER_KEY"])
      assert fold!(registry).api_key == {:env, "T17_OTHER_KEY"}
    end
  end

  describe "agent list / show (AC7)" do
    test "an empty registry prints nothing, exit 0", %{registry: registry} do
      assert {:ok, ""} = agent(["list"], registry)
    end

    test "list folds each store's head: name + model + provider + soul head", %{
      registry: registry
    } do
      new!(registry)
      assert {:ok, out} = agent(["list"], registry)
      assert out =~ "wisp"
      assert out =~ "deepseek-v4-flash"
      assert out =~ "api.deepseek.com"
      assert out =~ "I am wisp, the quiet sibling."
    end

    test "show prints the full fold including the per-field heads", %{registry: registry} do
      new!(registry)
      assert {:ok, out} = agent(["show", "wisp"], registry)
      assert out =~ "soul: I am wisp, the quiet sibling."
      assert out =~ "model: deepseek-v4-flash"
      assert out =~ "api_key: env DEEPSEEK_API_KEY"
      assert out =~ "self_config: false"
      # the head ids are printed so the operator can retract by id
      assert out =~ fold!(registry).heads[:model]
    end

    test "show on an unknown agent is a legible error", %{registry: registry} do
      assert {:error, message} = agent(["show", "ghost"], registry)
      assert message =~ "ghost"
    end
  end

  describe "agent set / unset / set-soul (AC8)" do
    test "set appends an operator delta; the fold updates", %{registry: registry} do
      new!(registry)
      assert {:ok, message} = agent(["set", "wisp", "--model", "kimi-k3"], registry)
      assert message =~ "model"
      assert fold!(registry).model == "kimi-k3"
    end

    test "re-asserting the CURRENT fold value is a true no-op (no delta appended)", %{
      registry: registry
    } do
      new!(registry)
      before = length(store_lines(registry))
      assert {:ok, message} = agent(["set", "wisp", "--model", "deepseek-v4-flash"], registry)
      assert message =~ "no change"
      assert length(store_lines(registry)) == before
    end

    test "set A -> set B -> set A produces a NEW delta that re-wins the merge", %{
      registry: registry
    } do
      new!(registry)
      assert {:ok, _} = agent(["set", "wisp", "--model", "kimi-k3"], registry)
      before = length(store_lines(registry))
      # deepseek-v4-flash is a PREVIOUS value (the genesis layer) — a genuine change
      assert {:ok, _} = agent(["set", "wisp", "--model", "deepseek-v4-flash"], registry)
      assert length(store_lines(registry)) == before + 1
      assert fold!(registry).model == "deepseek-v4-flash"
    end

    test "unset appends a delta that clears the field", %{registry: registry} do
      new!(registry)
      assert fold!(registry).soul != nil
      assert {:ok, _} = agent(["unset", "wisp", "soul"], registry)
      assert fold!(registry).soul == nil
    end

    test "set-soul is sugar for set --soul", %{registry: registry} do
      new!(registry)
      assert {:ok, _} = agent(["set-soul", "wisp", "a fresh soul line"], registry)
      assert fold!(registry).soul == "a fresh soul line"
    end
  end

  describe "single-writer: write verbs vs a live daemon (P5 r3 MEDIUM-2)" do
    test "a held store lock REFUSES the write with the ctl repair; a dead lock is stale", %{
      registry: registry
    } do
      new!(registry)

      # a live daemon: the lock beside the store carries a LIVE OS pid (our
      # own — an in-VM daemon is still the single writer)
      lock = store_path(registry) <> ".lock"
      File.write!(lock, System.pid())

      before = store_lines(registry)
      assert {:error, message} = agent(["set", "wisp", "--model", "kimi-k3"], registry)
      # legible: names the agent, says it is live, points at the ctl path
      assert message =~ "wisp"
      assert message =~ "live"
      assert message =~ "ctl set-config"
      # NO delta landed behind the daemon's back — the store is untouched
      assert store_lines(registry) == before

      # retract is a write verb too: same refusal
      assert {:error, retract_message} =
               agent(["retract", "wisp", "deadbeef"], registry)

      assert retract_message =~ "live"

      # a dead pid's lock is STALE: the offline mutation path stands
      File.write!(lock, "999999999")
      assert {:ok, _} = agent(["set", "wisp", "--model", "kimi-k3"], registry)
      assert fold!(registry).model == "kimi-k3"
    end

    test "new --force refuses to destroy a LIVE agent's store (P5 r6 MEDIUM-1)", %{
      registry: registry
    } do
      new!(registry)

      # a live daemon holds the store lock — `new --force` must not rm_rf
      # the store out from under it (the daemon would keep appending to an
      # unlinked file; every later delta orphaned, plus a double-writer at
      # the same path)
      lock = store_path(registry) <> ".lock"
      File.write!(lock, System.pid())

      before = File.read!(store_path(registry))

      assert {:error, message} =
               agent(
                 ["new", "wisp", "--soul", "usurper", "--force"] ++
                   ["--operator-seed-env", "T17_OP_SEED"],
                 registry
               )

      # legible routing: names the agent, says it is live, points at the
      # stop-the-daemon / ctl paths — and NOTHING was deleted
      assert message =~ "wisp"
      assert message =~ "live"
      assert message =~ "stop"
      assert message =~ "ctl"
      assert File.read!(store_path(registry)) == before
      assert File.exists?(lock)

      # a dead pid's lock is STALE: --force proceeds and recreates as before
      File.write!(lock, "999999999")

      assert {:ok, _} =
               agent(
                 ["new", "wisp", "--soul", "renewed", "--force"] ++
                   ["--operator-seed-env", "T17_OP_SEED"],
                 registry
               )

      assert fold!(registry).soul == "renewed"
      # the rebuild ran under the held lock and released it (P5 r8 LOW-1)
      refute File.exists?(lock)
    end

    test "the guard is ATOMIC (P5 r8 LOW-1): the append is gated on CREATING the lock", %{
      registry: registry
    } do
      new!(registry)
      dir = Path.join(registry, "wisp")

      # No lock exists, so the old advisory READ waved the write through —
      # the TOCTOU. Post-fix the O_EXCL create IS the liveness check: a dir
      # where the lock cannot be created (stand-in for losing the create
      # race) refuses the write outright, even though the store FILE itself
      # stays appendable.
      before = store_lines(registry)
      File.chmod!(dir, 0o555)

      try do
        assert {:error, message} = agent(["set", "wisp", "--model", "kimi-k3"], registry)
        assert message =~ "lock"
      after
        File.chmod!(dir, 0o755)
      end

      # refused CLEANLY: no partial append, store byte-unchanged
      assert store_lines(registry) == before
    end

    test "a successful write holds then releases the lock — no stale lock left behind (P5 r8 LOW-1)",
         %{registry: registry} do
      new!(registry)
      lock = store_path(registry) <> ".lock"
      refute File.exists?(lock)

      before = length(store_lines(registry))
      assert {:ok, _} = agent(["set", "wisp", "--model", "kimi-k3"], registry)
      assert length(store_lines(registry)) == before + 1

      # created-then-removed: a left-behind lock would refuse every later
      # writer (CLI and daemon boot both contend for this file)
      refute File.exists?(lock)

      # an ERROR inside the locked section releases too (the after path)
      assert {:error, _} = agent(["retract", "wisp", String.duplicate("00", 32)], registry)
      refute File.exists?(lock)
    end
  end

  describe "agent retract (AC13/AC15/AC16)" do
    test "retracting the override steps the fold back to the genesis layer", %{
      registry: registry
    } do
      new!(registry)
      assert {:ok, _} = agent(["set", "wisp", "--model", "kimi-k3"], registry)
      %{heads: %{model: override_id}} = fold!(registry)

      assert {:ok, _} = agent(["retract", "wisp", override_id], registry)
      assert fold!(registry).model == "deepseek-v4-flash"

      # the retracted delta stays byte-present (the store only learns)
      assert Enum.any?(store_lines(registry), &(&1 =~ override_id))
    end

    test "retracting an unknown delta id is a legible refusal", %{registry: registry} do
      new!(registry)
      ghost = String.duplicate("00", 32)
      assert {:error, message} = agent(["retract", "wisp", ghost], registry)
      assert message =~ ghost
    end

    test "retracting every AgentSet delta empties the fold: show reports no live config", %{
      registry: registry
    } do
      new!(registry)

      agent_set_ids =
        for {id, {claims, _sig}} <- load_set(registry),
            %{type: "AgentSet"} <- [Schema.resolve(claims)],
            do: id

      Enum.each(agent_set_ids, fn id ->
        assert {:ok, _} = agent(["retract", "wisp", id], registry)
      end)

      assert Config.resolve(load_set(registry), "wisp") == :not_found
      assert {:ok, message} = agent(["show", "wisp"], registry)
      assert message =~ "no live config"
    end
  end

  describe "the door (AC17/AC21)" do
    test "a key VALUE on argv is refused with the repair message; NO delta appended", %{
      registry: registry
    } do
      new!(registry)
      before = store_lines(registry)

      assert {:error, message} =
               agent(["set", "wisp", "--api-key", "sk-abcdef1234567890abcdef"], registry)

      assert message =~ "env NAME"
      assert store_lines(registry) == before
    end

    test "a secret-shaped soul is refused; NO delta appended", %{registry: registry} do
      new!(registry)
      before = store_lines(registry)

      assert {:error, message} =
               agent(["set", "wisp", "--soul", "my key is sk-abcdefghij1234567890"], registry)

      assert message =~ "env NAME"
      assert store_lines(registry) == before
    end

    test "AC21: a 64-hex seed VALUE in --operator-seed-env is refused at the door", %{
      registry: registry
    } do
      new!(registry)
      before = store_lines(registry)

      assert {:error, message} =
               agent(["set", "wisp", "--operator-seed-env", @operator_seed], registry)

      assert message =~ "env NAME"
      assert store_lines(registry) == before
    end
  end

  describe "encrypted-at-rest + rekey (AC20)" do
    test "set --api-key reads STDIN, writes {enc} ciphertext, never the plaintext", %{
      registry: registry
    } do
      new!(registry)
      secret = "sk-live-supersecret-value-123456"

      capture_io([input: secret <> "\n"], fn ->
        send(self(), CLI.run(["agent", "set", "wisp", "--api-key", "--registry", registry]))
      end)

      assert_received {:ok, _message}

      assert {:enc, ciphertext} = fold!(registry).api_key
      assert Secrets.decrypt(ciphertext, @operator_seed) == {:ok, secret}

      # the plaintext is nowhere: not in the store bytes, not in show
      refute File.read!(store_path(registry)) =~ secret
      assert {:ok, shown} = agent(["show", "wisp"], registry)
      refute shown =~ secret
      assert shown =~ "api_key: enc "
    end

    test "rekey re-encrypts under the new seed; the old seed no longer decrypts", %{
      registry: registry
    } do
      new!(registry)
      secret = "sk-live-supersecret-value-123456"

      capture_io([input: secret <> "\n"], fn ->
        send(self(), CLI.run(["agent", "set", "wisp", "--api-key", "--registry", registry]))
      end)

      assert_received {:ok, _}

      System.put_env("T17_NEW_SEED", @new_seed)
      assert {:ok, _} = agent(["rekey", "wisp", "--new-seed-env", "T17_NEW_SEED"], registry)

      assert {:enc, ciphertext} = fold!(registry).api_key
      assert Secrets.decrypt(ciphertext, @new_seed) == {:ok, secret}
      assert Secrets.decrypt(ciphertext, @operator_seed) == {:error, :decrypt_failed}

      # P5 round-7 HIGH-1 (AC21): rekey serializes NEITHER seed — the new
      # decrypt key lives only in the environment, never beside the store
      assert_no_seed_on_disk!(registry, [@operator_seed, @new_seed])
    end

    # P5 round-11 MEDIUM-4: rekey rotates the SEED, not the KEY. The store
    # only learns — the blob encrypted under the old seed is in the
    # append-only log forever, and anyone holding that seed can still read
    # it. Re-encryption is not revocation of the value; the only remedy is
    # rotating the credential at the provider. Rekey must SAY so, and name
    # the delta carrying the old blob.
    test "rekey narrates the permanent exposure and names the old blob's delta (P5 r11 M4 T1)",
         %{registry: registry} do
      new!(registry)
      secret = "sk-live-supersecret-value-123456"

      capture_io([input: secret <> "\n"], fn ->
        send(self(), CLI.run(["agent", "set", "wisp", "--api-key", "--registry", registry]))
      end)

      assert_received {:ok, _}

      old_blob_id = fold!(registry).heads[:api_key_enc]
      assert is_binary(old_blob_id)

      System.put_env("T17_NEW_SEED", @new_seed)
      assert {:ok, message} = agent(["rekey", "wisp", "--new-seed-env", "T17_NEW_SEED"], registry)

      assert message =~ "ROTATE the old key at the provider"
      assert message =~ "append-only"
      assert message =~ old_blob_id

      # and the old ciphertext IS still there, still readable under the old
      # seed — the narration is honest about the store, not decorative
      assert File.read!(store_path(registry)) =~ old_blob_id
    end

    test "rekey with no stored secret says nothing about rotation (P5 r11 M4)", %{
      registry: registry
    } do
      new!(registry)
      System.put_env("T17_NEW_SEED", @new_seed)
      assert {:ok, message} = agent(["rekey", "wisp", "--new-seed-env", "T17_NEW_SEED"], registry)

      assert message =~ "authority"
      refute message =~ "ROTATE"
    end

    test "the rekey help text states the append-only permanence (P5 r11 M4 T2)" do
      assert {:error, :usage, usage} = CLI.run(["agent", "bogus"])
      assert usage =~ "APPEND-ONLY"
      assert usage =~ "ROTATE the key"
    end

    test "rekey moves SIGNING authority in the same operation: B signs, A fails loudly (P5 M2)",
         %{registry: registry} do
      new!(registry)
      secret = "sk-live-supersecret-value-123456"

      capture_io([input: secret <> "\n"], fn ->
        send(self(), CLI.run(["agent", "set", "wisp", "--api-key", "--registry", registry]))
      end)

      assert_received {:ok, _}

      System.put_env("T17_NEW_SEED", @new_seed)
      assert {:ok, message} = agent(["rekey", "wisp", "--new-seed-env", "T17_NEW_SEED"], registry)
      assert message =~ "authority"

      new_author = Keys.author_for_seed(@new_seed)

      # P5 HIGH-3: the pointer chain is REPLACED — the old author is revoked
      pointer = pointer!(registry)
      assert pointer["operator_authors"] == [new_author]

      # the snapshot delta carries the new seed env — the plain verbs resolve
      # the NEW seed automatically and its deltas fold under the chain pin
      assert {:ok, _} = agent(["set", "wisp", "--model", "kimi-k3"], registry)

      {:ok, view} = Config.resolve(load_set(registry), "wisp", [new_author])
      assert view.model == "kimi-k3"
      assert view.operator_author == new_author
      assert view.heads[:model] != nil
      {claims, _sig} = load_set(registry)[view.heads[:model]]
      assert claims.author == new_author

      # signing with the ROTATED-AWAY seed fails loudly, appends nothing
      before = length(store_lines(registry))

      assert {:error, message} =
               agent(
                 ["set", "wisp", "--soul", "seized?", "--operator-seed-env", "T17_OP_SEED"],
                 registry
               )

      assert message =~ "not the CURRENT operator"
      assert length(store_lines(registry)) == before
    end

    test "a fresh agent's pointer records the operator author chain (P5 H2 anchor)", %{
      registry: registry
    } do
      new!(registry)
      assert pointer!(registry)["operator_authors"] == [Keys.author_for_seed(@operator_seed)]
    end

    test "a leaked rotated-away seed folds as NON-operator: no config seizure (P5 HIGH-3)", %{
      registry: registry
    } do
      new!(registry)
      System.put_env("T17_NEW_SEED", @new_seed)
      assert {:ok, _} = agent(["rekey", "wisp", "--new-seed-env", "T17_NEW_SEED"], registry)

      # the attacker still holds the OLD seed and appends straight to the
      # store, timestamped after everything else
      later = 1.0 * System.system_time(:millisecond) + 60_000

      append_raw!(registry, @operator_seed, later, %{
        model: "seized-model",
        base_url: "https://evil.example"
      })

      # under the pinned chain the old author is just another agent author
      # with no self_config grant: the delta is inert
      view = fold!(registry)
      assert view.operator_author == Keys.author_for_seed(@new_seed)
      assert view.model == "deepseek-v4-flash"
      assert view.base_url == "https://api.deepseek.com/v1"
    end

    test "an interrupted rekey never wedges: clear refusal or completion (P5 LOW-2)", %{
      registry: registry
    } do
      new!(registry)
      System.put_env("T17_NEW_SEED", @new_seed)
      pointer_path = Path.join([registry, "wisp", "agent.json"])
      pre = File.read!(pointer_path)

      assert {:ok, _} = agent(["rekey", "wisp", "--new-seed-env", "T17_NEW_SEED"], registry)

      # simulate the crash BETWEEN the store append and the pointer write:
      # the deltas landed; the pointer still carries the old chain
      File.write!(pointer_path, pre)

      # not a wedge: the verbs still resolve under the old chain
      assert {:ok, shown} = agent(["show", "wisp"], registry)
      assert shown =~ "model: deepseek-v4-flash"

      # the BARE re-run refuses CLEARLY (the folded seed env names the new
      # seed, which the still-old chain does not recognize)...
      assert {:error, message} =
               agent(["rekey", "wisp", "--new-seed-env", "T17_NEW_SEED"], registry)

      assert message =~ "not the CURRENT operator"

      # ...and the documented explicit re-run completes the handoff
      assert {:ok, _} =
               agent(
                 [
                   "rekey",
                   "wisp",
                   "--new-seed-env",
                   "T17_NEW_SEED",
                   "--operator-seed-env",
                   "T17_OP_SEED"
                 ],
                 registry
               )

      assert pointer!(registry)["operator_authors"] == [Keys.author_for_seed(@new_seed)]
      assert fold!(registry).operator_author == Keys.author_for_seed(@new_seed)
    end
  end

  describe "agent name validation (P5 HIGH-2)" do
    test "a traversal name is refused on EVERY verb; the target dir survives --force", %{
      registry: registry
    } do
      # the would-be victim: a sibling of the registry — exactly what
      # `agent new ../<dir> --force` used to rm_rf
      victim =
        Path.join(Path.dirname(registry), "t17-victim-#{System.os_time()}-#{System.unique_integer([:positive])}")

      File.mkdir_p!(victim)
      canary = Path.join(victim, "keep.txt")
      File.write!(canary, "precious")
      on_exit(fn -> File.rm_rf(victim) end)

      evil = "../" <> Path.basename(victim)

      assert {:error, message} =
               agent(["new", evil, "--force", "--operator-seed-env", "T17_OP_SEED"], registry)

      assert message =~ "invalid agent name"
      assert File.read!(canary) == "precious"

      for args <- [
            ["show", evil],
            ["set", evil, "--model", "x"],
            ["set-soul", evil, "seized"],
            ["unset", evil, "soul"],
            ["retract", evil, String.duplicate("00", 32)],
            ["rekey", evil, "--new-seed-env", "T17_NEW_SEED"],
            ["tombstone", evil, String.duplicate("00", 32), "--field", "soul"]
          ] do
        assert {:error, message} = agent(args, registry)
        assert message =~ "invalid agent name"
      end

      assert File.read!(canary) == "precious"
    end

    test "an absolute-path name is refused; the target dir survives", %{registry: registry} do
      victim =
        Path.join(System.tmp_dir!(), "t17-abs-victim-#{System.os_time()}-#{System.unique_integer([:positive])}")

      File.mkdir_p!(victim)
      on_exit(fn -> File.rm_rf(victim) end)

      assert {:error, message} =
               agent(["new", victim, "--force", "--operator-seed-env", "T17_OP_SEED"], registry)

      assert message =~ "invalid agent name"
      assert File.dir?(victim)
    end

    test "daemon --agent refuses a traversal name", %{registry: registry} do
      assert {:error, message} =
               CLI.run(["daemon", "--agent", "../evil", "--registry", registry])

      assert message =~ "invalid agent name"
    end
  end

  describe "tombstone runbook (AC24)" do
    test "the tombstone verb retracts the delta and appends the SecretTombstone claim", %{
      registry: registry
    } do
      new!(registry)
      assert {:ok, _} = agent(["set", "wisp", "--system-prompt", "an oops that leaked"], registry)
      %{heads: %{system_prompt: leaky_id}} = fold!(registry)

      assert {:ok, message} =
               agent(["tombstone", "wisp", leaky_id, "--field", "system_prompt"], registry)

      assert message =~ leaky_id

      # the offending delta is negated: the fold steps back
      assert fold!(registry).system_prompt == nil

      # and the tombstone claim rides the store, surfaced by show
      assert {:ok, shown} = agent(["show", "wisp"], registry)
      assert shown =~ "tombstone"
      assert shown =~ leaky_id
    end
  end

  describe "usage" do
    test "a bare or malformed agent invocation is a usage error" do
      assert {:error, :usage, _} = CLI.run(["agent"])
      assert {:error, :usage, _} = CLI.run(["agent", "bogus"])
      assert {:error, :usage, _} = CLI.run(["agent", "new"])
    end
  end
end
