defmodule Kyber.KeysTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Kyber.Keys
  alias Rhizomatic.{Ed25519, Signer}

  @seed_hex String.duplicate("ab", 32)
  @other_seed_hex String.duplicate("cd", 32)

  setup do
    home =
      Path.join(
        System.tmp_dir!(),
        "kyber-keys-#{System.unique_integer([:positive])}-#{System.system_time(:nanosecond)}"
      )

    on_exit(fn -> File.rm_rf(home) end)
    {:ok, home: home}
  end

  defp perms(path) do
    {:ok, stat} = File.stat(path)
    stat.mode &&& 0o777
  end

  describe "mint_agent_seed/1" do
    test "writes agent.seed 0600 (hex, never printed) and returns the seed", %{home: home} do
      assert {:ok, seed_hex} = Keys.mint_agent_seed(home)
      assert seed_hex =~ ~r/\A[0-9a-f]{64}\z/
      assert File.read!(Path.join(home, "agent.seed")) == seed_hex
      assert perms(Path.join(home, "agent.seed")) == 0o600
    end

    test "refuses to clobber an existing agent.seed", %{home: home} do
      assert {:ok, _} = Keys.mint_agent_seed(home)
      assert {:error, :already_exists} = Keys.mint_agent_seed(home)
    end

    test "returns an error when the home dir cannot be created", %{home: home} do
      File.write!(home, "not a dir")
      assert {:error, _} = Keys.mint_agent_seed(home)
    end
  end

  describe "load_agent_seed/1" do
    test "reads back the minted seed", %{home: home} do
      assert {:ok, seed_hex} = Keys.mint_agent_seed(home)
      assert {:ok, ^seed_hex} = Keys.load_agent_seed(home)
    end

    test "imports KYBER_SEED on first load and persists it", %{home: home} do
      System.put_env("KYBER_SEED", @seed_hex)
      on_exit(fn -> System.delete_env("KYBER_SEED") end)

      assert {:ok, @seed_hex} = Keys.load_agent_seed(home)
      assert File.read!(Path.join(home, "agent.seed")) == @seed_hex
      assert perms(Path.join(home, "agent.seed")) == 0o600

      # subsequent loads read the file, not the env
      System.delete_env("KYBER_SEED")
      assert {:ok, @seed_hex} = Keys.load_agent_seed(home)
    end

    test "errors when there is no file and no KYBER_SEED", %{home: home} do
      System.delete_env("KYBER_SEED")
      assert {:error, :no_agent_seed} = Keys.load_agent_seed(home)
    end

    test "trims a trailing newline from KYBER_SEED (dotenv files)", %{home: home} do
      System.put_env("KYBER_SEED", @seed_hex <> "\n")
      assert {:ok, @seed_hex} = Keys.load_agent_seed(home)
    after
      System.delete_env("KYBER_SEED")
    end
  end

  describe "import_human_seed/2" do
    test "stores the human seed 0600", %{home: home} do
      assert :ok = Keys.import_human_seed(@seed_hex, home)
      assert File.read!(Path.join(home, "human.seed")) == @seed_hex
      assert perms(Path.join(home, "human.seed")) == 0o600
    end

    test "rejects a malformed seed", %{home: home} do
      assert {:error, :invalid_seed} = Keys.import_human_seed("not-hex", home)
      assert {:error, :invalid_seed} = Keys.import_human_seed(String.duplicate("ab", 31), home)
    end
  end

  describe "author_for_seed/1" do
    test "derives the ed25519 author id from the seed" do
      seed = Base.decode16!(@seed_hex, case: :mixed)
      pub_hex = Base.encode16(Ed25519.public_key(seed), case: :lower)
      assert Keys.author_for_seed(@seed_hex) == "ed25519:" <> pub_hex
    end
  end

  describe "sign/2" do
    test "wraps Rhizomatic.Signer.sign/2" do
      claims = %{
        timestamp: 1_754_512_345_678.0,
        author: Keys.author_for_seed(@seed_hex),
        pointers: [%{role: "r", target: {:string, "x"}}]
      }

      seed = Base.decode16!(@seed_hex, case: :mixed)
      assert {:ok, sig_hex} = Keys.sign(claims, @seed_hex)
      assert {:ok, ^sig_hex} = Signer.sign(claims, seed)
      assert Signer.verify(claims, sig_hex)
    end

    test "rejects a malformed seed" do
      claims = %{
        timestamp: 1.0,
        author: "ed25519:" <> String.duplicate("00", 32),
        pointers: [%{role: "r", target: {:string, "x"}}]
      }

      assert {:error, :invalid_seed} = Keys.sign(claims, "zz")
    end

    test "rejects claims whose author does not match the seed" do
      claims = %{
        timestamp: 1.0,
        author: Keys.author_for_seed(@other_seed_hex),
        pointers: [%{role: "r", target: {:string, "x"}}]
      }

      assert {:error, :author_key_mismatch} = Keys.sign(claims, @seed_hex)
    end
  end
end
