defmodule Kyber.Agent.AttributionTest do
  @moduledoc """
  T14j AC2 (C2 — the Discord-user attribution): the `discordUser` pointer
  mints at ingest (`"discord:user:" <> author_id`, string-kind BY PIN),
  round-trips through the loam (Rhizomatic.Profile — N5), and the legacy
  received deltas (no pointer) resolve identically: the /7 nil arm omits
  the pointer ENTIRELY (byte-identical to /6 — no `%{role: "discordUser",
  target: nil}` residue). The role is `discordUser`, NEVER `author` — a
  role named `author` would silently overwrite the signer on every resolved
  MessageReceived (the compiler's merge-over citation). An unknown role
  refuses at the door. The folds render NOTHING new: attribution is data,
  never a decision surface (the conversation lens is byte-unchanged). The
  replay-stability witness (NEW-5): the mint is a pure function of the
  dispatch — re-ingesting the same frame re-mints the same content-derived
  id and merge-is-union collapses to exactly one record.
  """
  use ExUnit.Case, async: false

  alias Kyber.{DurableStore, Keys, Schema, Wire}
  alias Kyber.Agent.ContextBuilder
  alias Kyber.Channel.Test.{FakeDelivery, FakeTransport}
  alias Rhizomatic.{Delta, Profile}

  @human_seed String.duplicate("cd", 32)
  @operator_seed String.duplicate("7f", 32)
  @server "999"
  @channel "111"
  @token "BOT_TEST_TOKEN_" <> String.duplicate("ab", 16)
  @ts 1_754_600_000_000.0

  # -------------------------------------------------- the T5/T6/T7/T8 lifecycle
  setup_all do
    keyring_dir = Application.get_env(:kyber, :keyring_dir)
    config_log_path = Application.get_env(:kyber, :log_path)
    assert is_binary(keyring_dir)
    assert is_binary(config_log_path)

    on_exit(fn ->
      stop_app()
      Application.put_env(:kyber, :log_path, config_log_path)
    end)

    {:ok, keyring_dir: keyring_dir}
  end

  defp stop_app do
    case Application.stop(:kyber) do
      :ok -> :ok
      {:error, {:not_started, :kyber}} -> :ok
      other -> other
    end
  end

  defp fresh_dir(base, tag) do
    Path.join(
      base,
      "kyber-attribution-#{tag}-#{System.unique_integer([:positive])}-#{System.system_time(:nanosecond)}"
    )
  end

  defp boot_on(log_path) do
    stop_app()
    Application.put_env(:kyber, :log_path, log_path)
    assert {:ok, _} = Application.ensure_all_started(:kyber)
    assert is_pid(Process.whereis(DurableStore))
  end

  setup do
    log_dir = fresh_dir(System.tmp_dir!(), "log")
    log_path = Path.join(log_dir, "store.jsonl")
    boot_on(log_path)

    on_exit(fn ->
      stop_app()
      File.rm_rf(log_dir)
    end)

    :ok
  end

  # ---------------------------------------------------------------- helpers

  defp pointer(%{pointers: pointers}, role) do
    case Enum.find(pointers, &(&1.role == role)) do
      %{target: target} -> target
      nil -> nil
    end
  end

  defp first_role(%{pointers: [%{role: role} | _rest]}), do: role
  defp first_role(_claims), do: nil

  defp poll_until(pred, attempts \\ 200) do
    Enum.reduce_while(1..attempts, false, fn _, _ ->
      if pred.() do
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

  defp start_adapter!(opts \\ []) do
    {:ok, fake_t} = FakeTransport.start_link(server: @server, heartbeat_interval: 5_000)
    {:ok, fake_d} = FakeDelivery.start_link()

    adapter_opts =
      Keyword.merge(
        [
          server: @server,
          seed: Keys.derive_seed(@operator_seed, "kyber:discord-server:" <> @server),
          token_holder: fn -> @token end,
          transport: {FakeTransport, %{fake: fake_t}},
          delivery: {FakeDelivery, %{pid: fake_d}},
          tick_ms: 250
        ],
        opts
      )

    assert {:ok, adapter} = Kyber.Channel.Adapter.start_link(adapter_opts)
    {fake_t, fake_d, adapter}
  end

  defp discord_message(content, author) do
    %{
      "id" => "1001",
      "channel_id" => @channel,
      "guild_id" => @server,
      "author" => author,
      "content" => content
    }
  end

  defp received_claims_with_content(content) do
    Enum.find_value(DurableStore.set(), fn {_id, {claims, _sig}} ->
      case pointer(claims, "content") do
        {:string, ^content} -> claims
        _other -> nil
      end
    end)
  end

  # ------------------------------------------------------------------- AC2

  test "AC2: message_received/7 with an author mints the discordUser pointer — \"discord:user:\" <> id, string-kind, validated at the door" do
    {:ok, {claims, _sig}} =
      Kyber.Events.message_received(
        @human_seed,
        @ts,
        "msg:1",
        "channel:cli",
        "session:1",
        "hello",
        "discord:user:12345"
      )

    # the pointer rides as a STRING (string-kind BY PIN — the T14i L2
    # bare-`discord:` rejection governs entity ids only)
    assert pointer(claims, "discordUser") == {:string, "discord:user:12345"}

    # the door validates the claim TYPED against the evolved genesis schema
    assert {:ok, typed} = Schema.validate(claims)
    assert typed.type == "MessageReceived"
    assert typed.discordUser == "discord:user:12345"
  end

  test "AC2: the loam round-trip (N5) — the new-shape claim re-parses to the same content-derived id via Rhizomatic.Profile" do
    for discord_user <- ["discord:user:12345", nil] do
      {:ok, {claims, _sig}} =
        Kyber.Events.message_received(
          @human_seed,
          @ts,
          "msg:roundtrip",
          "channel:cli",
          "session:1",
          "hello",
          discord_user
        )

      # the JSON debug profile shape -> parse_claims (the loam door)
      json = claims |> Kyber.Wire.claims_json() |> JSON.encode!()
      assert {:ok, reparsed} = json |> JSON.decode!() |> Profile.parse_claims()
      assert Delta.id_hex(reparsed) == Delta.id_hex(claims)
    end
  end

  test "AC2: the /7 nil arm is BYTE-IDENTICAL to /6 — the pointer is omitted ENTIRELY, no nil residue" do
    {:ok, {legacy, _sig}} =
      Kyber.Events.message_received(@human_seed, @ts, "msg:2", "channel:cli", "session:1", "hello")

    {:ok, {nil_arm, _sig}} =
      Kyber.Events.message_received(
        @human_seed,
        @ts,
        "msg:2",
        "channel:cli",
        "session:1",
        "hello",
        nil
      )

    assert nil_arm == legacy
    assert Delta.id_hex(nil_arm) == Delta.id_hex(legacy)
    assert pointer(nil_arm, "discordUser") == nil
    refute Enum.any?(nil_arm.pointers, &(&1.role == "discordUser"))
  end

  test "AC2: the role is discordUser, NEVER author — an author-named role is refused at the door (the merge-over citation)" do
    # a claim carrying a pointer role the schema does not know refuses —
    # including the tempting "author" spelling (which would silently
    # overwrite the signer on every resolved MessageReceived)
    {:ok, {claims, _sig}} =
      Kyber.Events.message_received(@human_seed, @ts, "msg:3", "channel:cli", "session:1", "hello")

    tampered = %{claims | pointers: claims.pointers ++ [%{role: "author", target: {:string, "discord:user:1"}}]}

    assert {:error, {:unknown_role, "author"}} = Schema.validate(tampered)
  end

  test "AC2: the fold renders NOTHING new — the conversation lens is byte-unchanged for pointer-carrying received deltas" do
    # two received deltas, one legacy and one discordUser-carrying
    {:ok, {legacy, _sig}} =
      Kyber.Events.message_received(@human_seed, @ts, "msg:legacy", "channel:cli", "session:s1", "same text")

    {:ok, {with_attr, _sig}} =
      Kyber.Events.message_received(
        @human_seed,
        @ts + 1,
        "msg:attr",
        "channel:cli",
        "session:s1",
        "same text",
        "discord:user:999"
      )

    set = %{
      Delta.id_hex(legacy) => {legacy, _sig},
      Delta.id_hex(with_attr) => {with_attr, _sig}
    }

    turns = ContextBuilder.conversation(set, "session:s1")

    # both render as plain user turns — the attribution is data, never a
    # decision surface (role/content identical; only the content-derived id
    # and timestamp differ)
    assert length(turns) == 2
    assert Enum.all?(turns, &(&1.role == "user" and &1.content == "same text"))
  end

  # --------------------------------------------------- the adapter mint (AC2)

  test "AC2: the adapter mints the pointer at ingest — author id rides as \"discord:user:<id>\"; a missing/whitespace author mints nil (fail-closed)" do
    {fake_t, _fake_d, _adapter} = start_adapter!()

    assert poll_until(fn -> FakeTransport.identified?(fake_t) end)

    # a real author id -> the pointer rides
    :ok = FakeTransport.inject_message(fake_t, discord_message("hello", %{"id" => "user-1", "bot" => false}))

    assert poll_until(fn -> received_claims_with_content("hello") != nil end)
    authored = received_claims_with_content("hello")
    assert pointer(authored, "discordUser") == {:string, "discord:user:user-1"}

    # a missing author -> nil arm, NO pointer
    :ok = FakeTransport.inject_message(fake_t, discord_message("no author", nil))
    assert poll_until(fn -> received_claims_with_content("no author") != nil end)
    assert pointer(received_claims_with_content("no author"), "discordUser") == nil

    # a whitespace-only author id -> nil arm (fail-closed)
    :ok = FakeTransport.inject_message(fake_t, discord_message("blank author", %{"id" => "   ", "bot" => false}))
    assert poll_until(fn -> received_claims_with_content("blank author") != nil end)
    assert pointer(received_claims_with_content("blank author"), "discordUser") == nil
  end

  test "AC2 replay stability (NEW-5 / T-C2c): the mint is a pure function of the dispatch — re-ingesting the SAME frame re-mints the same delta and merge-is-union collapses to ONE record" do
    {fake_t, _fake_d, _adapter} = start_adapter!()
    assert poll_until(fn -> FakeTransport.identified?(fake_t) end)

    :ok = FakeTransport.inject_message(fake_t, discord_message("repeat me", %{"id" => "user-9", "bot" => false}))
    assert poll_until(fn -> received_claims_with_content("repeat me") != nil end)

    first = received_claims_with_content("repeat me")
    first_id = Delta.id_hex(first)
    assert pointer(first, "discordUser") == {:string, "discord:user:user-9"}

    # replay the exact same frame (same snowflake => same derived ts =>
    # same content-derived id)
    :ok = FakeTransport.inject_message(fake_t, discord_message("repeat me", %{"id" => "user-9", "bot" => false}))

    # exactly one record: the pointer-bearing claims with this content
    assert poll_until(fn ->
             Enum.count(DurableStore.set(), fn {_id, {claims, _sig}} ->
               match?({:string, "repeat me"}, pointer(claims, "content"))
             end) == 1
           end)

    [{^first_id, {claims, _sig}}] =
      Enum.filter(DurableStore.set(), fn {_id, {claims, _sig}} ->
        match?({:string, "repeat me"}, pointer(claims, "content"))
      end)

    assert pointer(claims, "discordUser") == {:string, "discord:user:user-9"}
  end
end
