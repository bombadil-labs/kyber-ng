defmodule Kyber.Agent.T17SecretsRedactorTest do
  @moduledoc """
  T17 — secret hardening, unit level (AC17, AC20, AC21, AC22, AC24).

  Secrets: HKDF-SHA256 key derivation from the operator seed
  (`kyber:agent-config:v1`) + AEAD encrypt/decrypt for `{"enc": ...}`
  values — wrong seed fails LOUDLY, never a wrong-key fallback.
  Redactor: exact-value + conservative shape-scan replacement with
  `[REDACTED]`; 64-hex content ids and `ed25519:` authors ride untouched.
  Door: plaintext keys refused; free-text fields shape- and entropy-
  scanned, fail-closed.
  """
  use ExUnit.Case, async: true

  alias Kyber.Agent.{Config, Redactor, Secrets}

  @seed String.duplicate("7f", 32)
  @other_seed String.duplicate("8a", 32)

  # ------------------------------------------------------------- Secrets

  describe "Secrets — encrypted-at-rest round-trip (AC20)" do
    test "encrypt/decrypt round-trips under the same seed" do
      {:ok, enc} = Secrets.encrypt("sk-live-abcdef1234567890", @seed)
      assert {:ok, "sk-live-abcdef1234567890"} = Secrets.decrypt(enc, @seed)
    end

    test "the ciphertext is base64 and never contains the plaintext" do
      plaintext = "sk-live-abcdef1234567890"
      {:ok, enc} = Secrets.encrypt(plaintext, @seed)
      assert {:ok, _} = Base.decode64(enc)
      refute enc =~ plaintext
    end

    test "a wrong seed fails loudly — never a wrong-key fallback" do
      {:ok, enc} = Secrets.encrypt("sk-live-abcdef1234567890", @seed)
      assert {:error, :decrypt_failed} = Secrets.decrypt(enc, @other_seed)
    end

    test "malformed ciphertext fails loudly" do
      assert {:error, :decrypt_failed} = Secrets.decrypt("not-base64!!!", @seed)
      assert {:error, :decrypt_failed} = Secrets.decrypt(Base.encode64("short"), @seed)
    end

    test "two encryptions of the same value differ (fresh nonce) but both decrypt" do
      {:ok, enc1} = Secrets.encrypt("value", @seed)
      {:ok, enc2} = Secrets.encrypt("value", @seed)
      refute enc1 == enc2
      assert {:ok, "value"} = Secrets.decrypt(enc1, @seed)
      assert {:ok, "value"} = Secrets.decrypt(enc2, @seed)
    end

    test "well_formed?/1 accepts real ciphertext, rejects junk (the door's shape check)" do
      {:ok, enc} = Secrets.encrypt("value", @seed)
      assert Secrets.well_formed?(enc)
      refute Secrets.well_formed?("not-base64!!!")
      refute Secrets.well_formed?(Base.encode64("short"))
    end

    test "derive_key/1 is deterministic per seed and 32 bytes (HKDF-SHA256)" do
      k1 = Secrets.derive_key(@seed)
      k2 = Secrets.derive_key(@seed)
      k3 = Secrets.derive_key(@other_seed)
      assert byte_size(k1) == 32
      assert k1 == k2
      refute k1 == k3
    end
  end

  # ------------------------------------------------------------ Redactor

  describe "Redactor — exact-value + shape-scan (AC22)" do
    test "a known secret value is replaced with [REDACTED]" do
      key = "my-provider-key-value-123456"
      text = "context with #{key} embedded"
      assert Redactor.redact(text, [key]) == "context with [REDACTED] embedded"
    end

    test "every occurrence is replaced, across multiple known values" do
      out = Redactor.redact("a SECRET1 b SECRET2 c SECRET1", ["SECRET1", "SECRET2"])
      assert out == "a [REDACTED] b [REDACTED] c [REDACTED]"
    end

    test "nil/empty known values are ignored" do
      assert Redactor.redact("hello", [nil, ""]) == "hello"
    end

    test "unknown sk-/api_/ghp_/AKIA/xoxb-shaped strings are shape-redacted" do
      assert Redactor.redact("token sk-abcdefghijklmnop1234 end", []) == "token [REDACTED] end"
      assert Redactor.redact("t api_abcdefghijklmnop1234 end", []) == "t [REDACTED] end"
      assert Redactor.redact("t ghp_abcdefghijklmnopqrstuv end", []) == "t [REDACTED] end"
      assert Redactor.redact("t AKIAIOSFODNN7EXAMPLE end", []) == "t [REDACTED] end"
      assert Redactor.redact("t xoxb-1234567890-abcdef end", []) == "t [REDACTED] end"
    end

    test "Bearer tokens and KEY= pairs are shape-redacted" do
      assert Redactor.redact("Authorization: Bearer abcdef1234567890abcdef", []) =~ "[REDACTED]"
      assert Redactor.redact("DEEPSEEK_API_KEY=abcdef1234567890abcdef", []) =~ "[REDACTED]"
    end

    test "NO false positives: 64-hex content ids and ed25519: authors ride untouched" do
      id = String.duplicate("ab", 32)
      author = "ed25519:" <> String.duplicate("cd", 32)
      text = "delta #{id} by #{author} answered"
      assert Redactor.redact(text, []) == text
    end

    test "ordinary prose and short tokens are untouched" do
      text = "The quiet sibling skims the surface; api_ and sk- alone are fine."
      assert Redactor.redact(text, []) == text
    end
  end

  # ---------------------------------------------------------------- Door

  describe "Config.validate_fields/1 — the door (AC17, AC21, AC24)" do
    test "a valid field set passes" do
      assert :ok =
               Config.validate_fields(%{
                 soul: "I am wisp, the quiet sibling.",
                 model: "deepseek-v4-flash",
                 api_key_env: "DEEPSEEK_API_KEY",
                 operator_seed_env: "WISP_OPERATOR_SEED",
                 loop: "reactor",
                 oracle_seed: "absent",
                 self_config: "false"
               })
    end

    test "api_key_env must be an env NAME — a plaintext key is refused" do
      assert {:error, {:invalid_field, :api_key_env, _}} =
               Config.validate_fields(%{api_key_env: "sk-live-abcdef1234567890"})

      assert {:error, {:invalid_field, :api_key_env, _}} =
               Config.validate_fields(%{api_key_env: "lower_case"})
    end

    test "api_key_enc must be well-formed ciphertext" do
      {:ok, enc} = Secrets.encrypt("value", @seed)
      assert :ok = Config.validate_fields(%{api_key_enc: enc})

      assert {:error, {:invalid_field, :api_key_enc, _}} =
               Config.validate_fields(%{api_key_enc: "sk-plaintext-key-1234567890"})
    end

    test "operator_seed_env is env-name-only — a 64-hex seed VALUE is refused (AC21)" do
      assert {:error, {:invalid_field, :operator_seed_env, _}} =
               Config.validate_fields(%{operator_seed_env: String.duplicate("ab", 32)})
    end

    test "a soul carrying an obvious secret shape is refused (AC17)" do
      assert {:error, {:secret_shaped, :soul, _}} =
               Config.validate_fields(%{soul: "I am wisp. sk-live-abcdef1234567890"})

      assert {:error, {:secret_shaped, :system_prompt, _}} =
               Config.validate_fields(%{
                 system_prompt: "use DEEPSEEK_API_KEY=abcdef1234567890abcdef"
               })
    end

    test "a soul carrying a >=32-char hex run is refused; short hex passes" do
      assert {:error, {:secret_shaped, :soul, _}} =
               Config.validate_fields(%{soul: "remember " <> String.duplicate("ab", 20)})

      assert :ok = Config.validate_fields(%{soul: "the id abcd1234 is fine"})
    end

    test "the fail-closed entropy scan refuses a long high-entropy token, passes prose (AC24)" do
      random = Base.encode64(:crypto.strong_rand_bytes(36))
      assert {:error, {:secret_shaped, :soul, _}} = Config.validate_fields(%{soul: "x #{random} y"})

      prose =
        "I am wisp, the quiet sibling — grounded, honest, eager; " <>
          "I skim surfaces and report what the water says."

      assert :ok = Config.validate_fields(%{soul: prose})
    end

    test "loop and oracle_seed are closed sets" do
      assert {:error, {:invalid_field, :loop, _}} = Config.validate_fields(%{loop: "spin"})

      assert {:error, {:invalid_field, :oracle_seed, _}} =
               Config.validate_fields(%{oracle_seed: "maybe"})
    end

    test "self_config is a closed boolean-string set" do
      assert {:error, {:invalid_field, :self_config, _}} =
               Config.validate_fields(%{self_config: "yes"})
    end

    test "unknown field names in unset are refused" do
      assert :ok = Config.validate_fields(%{unset: ["model", "soul"]})
      assert {:error, {:invalid_field, :unset, _}} = Config.validate_fields(%{unset: ["nonsense"]})
    end
  end
end
