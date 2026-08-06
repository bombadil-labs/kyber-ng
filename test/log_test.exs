defmodule Kyber.LogTest do
  use ExUnit.Case, async: true

  alias Kyber.{Events, Log, TestWire}

  @human_seed String.duplicate("cd", 32)
  @ts 1_754_512_345_678

  # keeps runtime artifacts out of the repo tree (never `ExUnit`'s built-in
  # `:tmp_dir` tag, which resolves under the project root)
  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "kyber-log-#{System.unique_integer([:positive])}-#{System.system_time(:nanosecond)}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, tmp_dir: dir}
  end

  defp wire(message_id \\ "message:discord:111111111111111111:1") do
    assert {:ok, signed} =
             Events.message_received(
               @human_seed,
               @ts,
               message_id,
               "channel:discord:111111111111111111",
               "session:discord:111111111111111111",
               "hello Veles"
             )

    TestWire.envelope(signed)
  end

  describe "open/1" do
    test "creates the file in append mode", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "log.jsonl")
      refute File.exists?(path)

      assert {:ok, io} = Log.open(path)
      assert File.exists?(path)
      File.close(io)
    end

    test "opens an existing file without truncating it", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "log.jsonl")

      assert {:ok, io1} = Log.open(path)
      assert :ok = Log.append(io1, wire("message:discord:111111111111111111:1"))
      File.close(io1)

      assert {:ok, io2} = Log.open(path)
      assert :ok = Log.append(io2, wire("message:discord:222222222222222222:2"))
      File.close(io2)

      assert Log.stream(path) |> Enum.count() == 2
    end
  end

  describe "append/2" do
    test "writes one JSON-encoded envelope per line, newline-terminated", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "log.jsonl")
      {:ok, io} = Log.open(path)
      envelope = wire()

      assert :ok = Log.append(io, envelope)
      File.close(io)

      content = File.read!(path)
      assert String.ends_with?(content, "\n")
      assert [line] = content |> String.trim_trailing("\n") |> String.split("\n")
      assert {:ok, decoded} = JSON.decode(line)
      assert decoded == envelope
    end

    test "accumulates multiple envelopes across calls", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "log.jsonl")
      {:ok, io} = Log.open(path)

      assert :ok = Log.append(io, wire("message:discord:111111111111111111:1"))
      assert :ok = Log.append(io, wire("message:discord:222222222222222222:2"))
      File.close(io)

      lines = Log.stream(path) |> Enum.to_list()
      assert length(lines) == 2
    end

    test "AC6: refuses non-map input and leaves the file unchanged", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "log.jsonl")
      {:ok, io} = Log.open(path)

      assert :ok = Log.append(io, wire())
      before = File.read!(path)

      assert {:error, {:encode, _reason}} = Log.append(io, "not a map")
      assert {:error, {:encode, _reason}} = Log.append(io, [1, 2, 3])
      File.close(io)

      assert File.read!(path) == before
    end

    test "AC6: refuses non-encodable input and leaves the file unchanged", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "log.jsonl")
      {:ok, io} = Log.open(path)

      assert :ok = Log.append(io, wire())
      before = File.read!(path)

      assert {:error, {:encode, _reason}} = Log.append(io, %{"a" => {1, 2}})
      assert {:error, {:encode, _reason}} = Log.append(io, %{"a" => self()})
      File.close(io)

      assert File.read!(path) == before
    end

    test "P5: refuses maps with non-string keys (stdlib coerces them — reject, never repair)", %{
      tmp_dir: tmp_dir
    } do
      path = Path.join(tmp_dir, "log.jsonl")
      {:ok, io} = Log.open(path)

      assert :ok = Log.append(io, wire())
      before = File.read!(path)

      assert {:error, {:encode, :non_string_key}} = Log.append(io, %{1 => "a", "b" => 2})
      assert {:error, {:encode, :non_string_key}} = Log.append(io, %{atom_key: "a"})
      File.close(io)

      assert File.read!(path) == before
    end
  end

  describe "stream/1" do
    test "returns zero lines for a missing path", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "nope.jsonl")
      refute File.exists?(path)
      assert Log.stream(path) |> Enum.to_list() == []
    end

    test "lazily yields the raw appended lines, in order, for replay", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "log.jsonl")
      {:ok, io} = Log.open(path)
      w1 = wire("message:discord:111111111111111111:1")
      w2 = wire("message:discord:222222222222222222:2")
      assert :ok = Log.append(io, w1)
      assert :ok = Log.append(io, w2)
      File.close(io)

      [line1, line2] = Log.stream(path) |> Enum.to_list()
      assert {:ok, w1} == JSON.decode(line1)
      assert {:ok, w2} == JSON.decode(line2)
    end

    test "a torn/truncated final line is handed back as-is, never fatal", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "log.jsonl")
      full = JSON.encode!(wire())
      fragment = String.slice(full, 0, 20)

      File.write!(path, full <> "\n" <> fragment)

      assert [line1, ^fragment] = Log.stream(path) |> Enum.to_list()
      assert {:ok, _} = JSON.decode(line1)
      assert {:error, _} = JSON.decode(fragment)
    end
  end
end
