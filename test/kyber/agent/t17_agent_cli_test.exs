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

  alias Kyber.{CLI, DeltaSet, Log, Schema, Store}
  alias Kyber.Agent.{Config, Secrets}

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

  defp fold!(registry) do
    {:ok, view} = Config.resolve(load_set(registry), "wisp")
    view
  end

  defp store_lines(registry), do: store_path(registry) |> Log.stream() |> Enum.to_list()

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
                 ["new", "wisp", "--soul", "renewed", "--force", "--operator-seed-env", "T17_OP_SEED"],
                 registry
               )

      assert fold!(registry).soul == "renewed"
    end

    test "an unresolvable operator seed env is a legible refusal, no store created", %{
      registry: registry
    } do
      System.delete_env("T17_OP_SEED")

      assert {:error, message} =
               agent(["new", "wisp", "--soul", "x", "--operator-seed-env", "T17_OP_SEED"], registry)

      assert message =~ "T17_OP_SEED"
      refute File.exists?(store_path(registry))
    end

    test "a born-broken fallback is refused: the genesis key env must be present", %{
      registry: registry
    } do
      System.delete_env("DEEPSEEK_API_KEY")

      assert {:error, message} =
               agent(["new", "wisp", "--soul", "x", "--operator-seed-env", "T17_OP_SEED"], registry)

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
