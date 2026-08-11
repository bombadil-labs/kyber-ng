defmodule Kyber.Channel.CodecTest do
  @moduledoc """
  T14i — the pure RFC 6455 codec (D1/M3): mask-injected encoding, the
  pinned strictness (the decoder REJECTS — never raises — masked server
  frames, RSV bits, oversized control frames, fragmented control frames),
  extended lengths 126/127 (the >64KB payload rides the 8-byte length),
  fragmentation reassembly, and the byte-exact mask/unmask algebra.
  """
  use ExUnit.Case, async: true

  alias Kyber.Channel.Codec

  @mask <<1, 2, 3, 4>>

  # ---------------------------------------------------------------- encode

  test "an unmasked text frame encodes byte-exactly" do
    frame = Codec.encode_frame("hello", 0x1)
    # FIN=1 rsv=000 opcode=0001 MASK=0 len=5
    assert <<0x81, 0x05, "hello">> == frame
  end

  test "a masked text frame encodes byte-exactly and round-trips" do
    frame = Codec.encode_frame("hello", 0x1, @mask)
    assert <<0x81, 0x85, @mask::binary, masked::binary>> = frame
    assert byte_size(masked) == 5
    assert {:ok, [{0x1, "hello"}], ""} == Codec.decode_frames(frame, mask: :expect)
  end

  test "the mask is an ARGUMENT — deterministic in tests, never trusted from the peer" do
    assert Codec.encode_frame("hi", 0x1, <<0, 0, 0, 0>>) == <<0x81, 0x82, 0, 0, 0, 0, "hi">>
    assert Codec.encode_frame("hi", 0x1, <<9, 9, 9, 9>>) != Codec.encode_frame("hi", 0x1, @mask)
  end

  test "the mask algebra is byte-exact (the XOR cycle)" do
    payload = "the quick brown fox"
    frame = Codec.encode_frame(payload, 0x1, @mask)
    assert {:ok, [{0x1, ^payload}], ""} = Codec.decode_frames(frame, mask: :expect)
  end

  test "extended length 126 (payloads 126..65535)" do
    payload = String.duplicate("x", 300)
    frame = Codec.encode_frame(payload, 0x2, @mask)
    assert <<0x82, 0xFE, 300::16, @mask::binary, _::binary>> = frame
    assert {:ok, [{0x2, ^payload}], ""} = Codec.decode_frames(frame, mask: :expect)
  end

  test "extended length 127 — a >64KB payload rides the 8-byte length" do
    payload = String.duplicate("y", 70_000)
    frame = Codec.encode_frame(payload, 0x2, @mask)
    assert <<0x82, 0xFF, 70_000::64, @mask::binary, _::binary>> = frame
    assert {:ok, [{0x2, ^payload}], ""} = Codec.decode_frames(frame, mask: :expect)
  end

  test "multiple frames in one buffer decode in order" do
    a = Codec.encode_frame("one", 0x1, @mask)
    b = Codec.encode_frame("two", 0x1, @mask)
    assert {:ok, [{0x1, "one"}, {0x1, "two"}], ""} = Codec.decode_frames(a <> b, mask: :expect)
  end

  # -------------------------------------------------------------- strictness

  test "the client decoder REJECTS a masked server frame (never raises)" do
    masked = Codec.encode_frame("sneaky", 0x1, @mask)
    assert {:error, :masked_server_frame} = Codec.decode_frames(masked)
  end

  test "the client decoder REJECTS RSV bits set" do
    # rsv1 = 1 on an unmasked text frame
    assert {:error, :rsv_set} = Codec.decode_frames(<<0xC1, 0x00>>)
  end

  test "the decoder REJECTS a control frame over 125 bytes" do
    assert {:error, :control_frame_too_large} = Codec.decode_frames(<<0x89, 126, 200::16, "x">>)
  end

  test "the decoder REJECTS a fragmented control frame (FIN=0 on a close frame)" do
    assert {:error, :fragmented_control_frame} = Codec.decode_frames(<<0x08, 0x00>>)
  end

  test "the server decoder REJECTS an unmasked client frame (RFC 6455)" do
    assert {:error, :unmasked_client_frame} = Codec.decode_frames(<<0x81, 0x00>>, mask: :expect)
  end

  test "the decoder REJECTS a continuation frame with no open fragment" do
    assert {:error, :continuation_without_fragment} = Codec.decode_frames(<<0x80, 0x00>>)
  end

  # ----------------------------------------------------------- fragmentation

  test "fragmented text reassembles with the ORIGINAL opcode within one buffer" do
    # FIN=0 text "hel" + continuation FIN=0 "lo " + final continuation "world"
    part1 = <<0x01, 0x03, "hel">>
    part2 = <<0x00, 0x03, "lo ">>
    part3 = <<0x80, 0x05, "world">>
    assert {:ok, [{0x1, "hello world"}], ""} = Codec.decode_frames(part1 <> part2 <> part3)
  end

  test "an incomplete fragment stays in `rest` — the caller accumulates and re-decodes (H1's sibling)" do
    part1 = <<0x01, 0x03, "hel">>
    part2 = <<0x00, 0x03, "lo ">>

    # only the non-final parts: nothing emits, the raw bytes stay in rest
    assert {:ok, [], rest} = Codec.decode_frames(part1 <> part2)
    assert rest != ""

    # the caller accumulates: rest <> the final continuation completes it
    part3 = <<0x80, 0x05, "world">>
    assert {:ok, [{0x1, "hello world"}], ""} = Codec.decode_frames(rest <> part3)
  end

  test "a partial trailing frame stays in rest" do
    frame = Codec.encode_frame("hello", 0x1, @mask)
    {head, tail} = String.split_at(frame, 6)
    assert {:ok, [], rest} = Codec.decode_frames(head, mask: :expect)
    assert {:ok, [{0x1, "hello"}], ""} = Codec.decode_frames(rest <> tail, mask: :expect)
  end

  # ------------------------------------------------------------------ pings

  test "ping and pong frames encode/decode (the auto-pong lives in the transport impl)" do
    ping = Codec.encode_frame("abc", 0x9, @mask)
    assert {:ok, [{0x9, "abc"}], ""} = Codec.decode_frames(ping, mask: :expect)
    pong = Codec.encode_frame("abc", 0xA, @mask)
    assert {:ok, [{0xA, "abc"}], ""} = Codec.decode_frames(pong, mask: :expect)
  end
end
