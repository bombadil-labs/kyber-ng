defmodule Kyber.Channel.TokenHygieneTest do
  @moduledoc """
  T14i AC5/D2/M12 — token hygiene: the proven-live sentinel scanner. The
  full fake-transport loop runs with a sentinel token; a claim carrying a
  SENTINEL marker is minted and the scanner FINDS it (a dead scanner cannot
  claim absence), THEN the real token is asserted ABSENT from the store's
  on-disk log BYTES, the rendered status bytes, and the adapter's
  inspectable state bytes. The scan is over store/log/status bytes — NEVER
  a lib/ grep. The token rides ONLY the delivery seam's Authorization
  header (H4); a `--token <value>` on argv is a usage error, exit 2 (the
  CLI arm asserts the ps-visible refusal).
  """
  use ExUnit.Case, async: false

  alias Kyber.{Daemon, DurableStore, Keys}
  alias Kyber.Agent.LlmHandler
  alias Kyber.Channel.Test.{FakeDelivery, FakeTransport}

  @human_seed String.duplicate("cd", 32)
  @operator_seed String.duplicate("7f", 32)
  @server "999"
  @channel "111"
  # the REAL token: what the operator's env would hold — never on argv,
  # never in the store/log/status bytes
  @token "ACTUAL_BOT_TOKEN_" <> String.duplicate("ab", 16)
  # the sentinel: a marker minted into a claim to prove the scanner is live
  @sentinel "SENTINEL_MARKER_" <> String.duplicate("cd", 8)

  defmodule StubLlm do
    @behaviour Kyber.Agent.HttpClient

    @impl true
    def post(_url, _headers, _body, _state) do
      body =
        JSON.encode!(%{
          "choices" => [
            %{"index" => 0, "message" => %{"role" => "assistant", "content" => "stub answer"}}
          ]
        })

      {:ok, %{status: 200, body: body}}
    end
  end

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
      "kyber-token-#{tag}-#{System.unique_integer([:positive])}-#{System.system_time(:nanosecond)}"
    )
  end

  defp boot_on(log_path) do
    stop_app()
    Application.put_env(:kyber, :log_path, log_path)
    assert {:ok, _} = Application.ensure_all_started(:kyber)
    assert is_pid(Process.whereis(DurableStore))
  end

  setup %{keyring_dir: keyring_dir} do
    key_dir = fresh_dir(keyring_dir, "keyring")
    File.mkdir_p!(key_dir)
    assert :ok = Keys.import_human_seed(@human_seed, key_dir)
    System.put_env("KYBER_SEED", String.duplicate("b2", 32))
    assert {:ok, _agent_seed} = Keys.mint_agent_seed(key_dir)

    log_dir = fresh_dir(System.tmp_dir!(), "log")
    log_path = Path.join(log_dir, "store.jsonl")
    boot_on(log_path)

    on_exit(fn ->
      Daemon.stop()
      stop_app()
      System.delete_env("KYBER_SEED")
      File.rm_rf(key_dir)
      File.rm_rf(log_dir)
    end)

    {:ok, keyring_dir: key_dir, log_path: log_path}
  end

  # ---------------------------------------------------------------- helpers

  defp stub_llm do
    {:ok, llm} =
      LlmHandler.new(
        seed: String.duplicate("b2", 32),
        api_key: "stub-key",
        http: {StubLlm, nil},
        model: "stub-model"
      )

    llm
  end

  defp boot_channel_daemon!(ctx) do
    assert {:ok, _pid} =
             Daemon.boot(
               keyring_dir: ctx.keyring_dir,
               tick_ms: :manual,
               loop: :reactor,
               oracle_seed: :present,
               operator_seed: @operator_seed,
               engine: [llm: stub_llm(), tools: %{"tool:echo" => fn args -> args end}],
               test_pid: self()
             )
  end

  defp start_adapter! do
    {:ok, fake_t} = FakeTransport.start_link(server: @server, heartbeat_interval: 5_000)
    {:ok, fake_d} = FakeDelivery.start_link()

    assert {:ok, adapter} =
             Kyber.Channel.Adapter.start_link(
               server: @server,
               seed: Keys.derive_seed(@operator_seed, "kyber:discord-server:" <> @server),
               token_holder: fn -> @token end,
               transport: {FakeTransport, %{fake: fake_t}},
               delivery: {FakeDelivery, %{pid: fake_d}},
               tick_ms: 250
             )

    {fake_t, fake_d, adapter}
  end

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

  defp first_role(%{pointers: [%{role: role} | _rest]}), do: role

  # the byte scanner: does `needle` appear in the on-disk store's log bytes?
  defp scan_log(log_path, needle), do: String.contains?(File.read!(log_path), needle)

  # the byte scanner over the rendered status (never a lib/ grep)
  defp scan_status(needle, adapter) do
    rendered = inspect({Daemon.status(), Kyber.Channel.Adapter.status(adapter)})
    String.contains?(rendered, needle)
  end

  # ------------------------------------------------------------------- AC5

  test "AC5: the proven-live sentinel scanner — the sentinel is FOUND live in the log bytes, the real token is ABSENT from the store/log/status bytes, and rides ONLY the delivery seam's Authorization header",
       ctx do
    boot_channel_daemon!(ctx)
    {fake_t, fake_d, adapter} = start_adapter!()

    assert poll_until(fn -> FakeTransport.identified?(fake_t) end)

    # the user-content false-positive class (M12, RECORDED): a user pasting
    # the sentinel into Discord lands it in MessageReceived content — the
    # liveness-minted sentinel persists in the test store's log bytes
    :ok =
      FakeTransport.inject_message(fake_t, %{
        "id" => "1001",
        "channel_id" => @channel,
        "guild_id" => @server,
        "author" => %{"id" => "user-1", "bot" => false},
        "content" => "the secret code is " <> @sentinel
      })

    # the claim (with the sentinel in its content) lands in the log
    assert poll_until(fn ->
             Enum.any?(DurableStore.set(), fn {_id, {claims, _sig}} ->
               first_role(claims) == "received"
             end)
           end)

    # THE SCANNER IS LIVE: it finds the sentinel in the log bytes — a dead
    # scanner could not claim absence
    assert scan_log(ctx.log_path, @sentinel),
           "the sentinel must be findable in the log bytes — the scanner is dead"

    # the token NEVER appears in the log bytes (the store), even though a
    # full transport+delivery loop ran with it
    refute scan_log(ctx.log_path, @token)

    # the token never appears in the rendered status bytes
    refute scan_status(@token, adapter)

    # M12: the token is held OUTSIDE inspectable state (a closure) — the
    # adapter's full state render shows the function, never the token
    refute inspect(:sys.get_state(adapter)) =~ @token

    # the token rides ONLY the delivery seam's header (H4): the fake
    # delivery recorded it in the Authorization header of the POST
    :ok = FakeTransport.inject_message(fake_t, %{
      "id" => "1002",
      "channel_id" => @channel,
      "guild_id" => @server,
      "author" => %{"id" => "user-2", "bot" => false},
      "content" => "deliver me"
    })

    # both injected messages were answered and delivered (the sentinel
    # message's chain too) — EVERY delivery carries the token header
    assert poll_until(fn -> length(FakeDelivery.posts(fake_d)) == 2 end)

    for {_url, headers, _body} <- FakeDelivery.posts(fake_d) do
      assert {"authorization", "Bot " <> @token} in headers,
             "the token must ride the delivery seam's Authorization header"
    end

    # the LAST delivery replies in-thread to the second message (1002)
    {_url, _headers, body} = List.last(FakeDelivery.posts(fake_d))
    assert JSON.decode!(body)["message_reference"]["message_id"] == "1002"

    refute scan_log(ctx.log_path, @token)
  end

  test "AC5: the token is absent from EVERY delta's bytes in the store (deltas carry no credentials)",
       ctx do
    boot_channel_daemon!(ctx)
    {fake_t, _fake_d, _adapter} = start_adapter!()
    assert poll_until(fn -> FakeTransport.identified?(fake_t) end)

    :ok =
      FakeTransport.inject_message(fake_t, %{
        "id" => "1003",
        "channel_id" => @channel,
        "guild_id" => @server,
        "author" => %{"id" => "user-3", "bot" => false},
        "content" => "hello"
      })

    assert poll_until(fn ->
             Enum.any?(DurableStore.set(), fn {_id, {claims, _sig}} ->
               first_role(claims) == "received"
             end)
           end)

    # every store delta's rendered bytes — claims AND signatures — lack the token
    set = DurableStore.set()

    Enum.each(set, fn {_id, {claims, sig}} ->
      refute inspect(claims) =~ @token
      refute sig =~ @token
    end)
  end
end
