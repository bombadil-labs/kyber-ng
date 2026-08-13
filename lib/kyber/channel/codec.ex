defmodule Kyber.Channel.Codec do
  @moduledoc """
  The pure RFC 6455 websocket codec (T14i D1), hand-rolled — ZERO new deps.

  **Mask-injected**: the 4-byte mask key is an ARGUMENT
  (`encode_frame(payload, opcode, mask_key)`) — crypto-random only at the
  live edge, deterministic in tests; it is never trusted from the peer.
  `mask_key: nil` (the default) encodes an UNMASKED frame (the server
  direction — the fake gateway in the suite); a 4-byte binary encodes a
  MASKED client frame.

  **Strictness pinned (M3)**: `decode_frames/1` is the CLIENT decoder — it
  REJECTS (returns `{:error, reason}`, never raises) masked server frames,
  RSV bits set, control frames > 125 bytes, and fragmented control frames.
  The server direction (`decode_frames(buffer, mask: :expect)`) accepts
  masked frames — the fake gateway's decoder in the suite.

  **Fragmentation reassembly**: a non-final data frame (FIN=0) opens a
  fragment accumulator, continuation frames (opcode 0x0) append, and the
  final continuation emits ONE frame with the ORIGINAL opcode. A fragment
  sequence that does not complete within the buffer stays in `rest` — the
  caller accumulates (`rest <> new_data`) and re-decodes (the transport's
  recv-accumulate discipline, H1's sibling).

  ping(0x9)→pong(0xA) cannot live in the pure codec (it cannot send): the
  transport IMPL auto-pongs internally (pinned, M3).
  """

  @opcode_continuation 0x0
  @opcode_text 0x1
  @opcode_binary 0x2

  @type frame :: {opcode :: 0..0xF, payload :: binary()}

  @doc """
  Encode one client/server frame. `mask_key`:
    - a 4-byte binary → a MASKED frame (client direction; the payload is
      XOR-masked with the key, cyclically);
    - `nil` → an UNMASKED frame (server direction).
  Extended lengths 126/127 are emitted when the payload demands them.
  """
  @spec encode_frame(binary(), 0..0xF, binary() | nil) :: binary()
  def encode_frame(payload, opcode, mask_key \\ nil)
      when is_binary(payload) and is_integer(opcode) do
    len = byte_size(payload)
    {len_bits, len_bytes} = length_field(len)
    mask_bit = if mask_key, do: 1, else: 0
    <<1::1, 0::3, opcode::4, mask_bit::1, len_bits::7>> <> len_bytes <> mask_bytes(mask_key) <>
      mask_payload(payload, mask_key)
  end

  @doc """
  Decode frames from a buffer. Client-side by default (`mask: :reject` —
  a masked frame from the server is a protocol violation, rejected);
  `mask: :expect` is the server direction. Returns `{:ok, frames, rest}`
  or `{:error, reason}`. An incomplete trailing frame (or an incomplete
  fragmented message) stays in `rest`.
  """
  @spec decode_frames(binary(), keyword()) ::
          {:ok, [frame()], binary()} | {:error, term()}
  def decode_frames(buffer, opts \\ []) when is_binary(buffer) do
    mask_mode = Keyword.get(opts, :mask, :reject)
    do_decode(buffer, [], [], mask_mode)
  end

  # ------------------------------------------------------------- machinery

  # {7-bit length bits, extended length bytes}
  defp length_field(len) when len < 126, do: {len, <<>>}
  defp length_field(len) when len <= 0xFFFF, do: {126, <<len::16>>}
  defp length_field(len), do: {127, <<len::64>>}

  defp mask_bytes(nil), do: <<>>
  defp mask_bytes(mask_key), do: mask_key

  defp mask_payload(payload, nil), do: payload

  defp mask_payload(payload, <<a, b, c, d>>) do
    mask_payload(payload, <<a, b, c, d>>, 0, [])
  end

  defp mask_payload(<<>>, _key, _i, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp mask_payload(<<byte, rest::binary>>, <<a, b, c, d>>, i, acc) do
    key = case rem(i, 4) do
      0 -> a
      1 -> b
      2 -> c
      3 -> d
    end

    mask_payload(rest, <<a, b, c, d>>, i + 1, [Bitwise.bxor(byte, key) | acc])
  end

  # parse one frame header; the strictness checks are pinned (M3).
  # `mask: :reject` (the client decoder) refuses masked server frames;
  # `mask: :expect` (the server decoder) requires them (RFC 6455).
  defp parse_header(<<fin::1, rsv::3, opcode::4, mask::1, len7::7, rest::binary>>) do
    with :ok <- check_rsv(rsv),
         :ok <- check_mask(mask) do
      parse_header_tail(fin, opcode, mask, len7, rest, :reject)
    end
  end

  defp parse_header(_), do: {:error, :short_frame}

  defp parse_header_server(<<fin::1, rsv::3, opcode::4, mask::1, len7::7, rest::binary>>) do
    with :ok <- check_rsv(rsv),
         :ok <- check_mask_server(mask) do
      parse_header_tail(fin, opcode, mask, len7, rest, :expect)
    end
  end

  defp parse_header_server(_), do: {:error, :short_frame}

  # the common tail: extended length (126/127), the 4-byte mask key, and the
  # pinned strictness (oversized/fragmented control frames)
  defp parse_header_tail(fin, opcode, mask, len7, rest, _mode) do
    case extended_length(len7, rest) do
      {:ok, ext_len, rest} ->
        case take_mask(mask, rest) do
          {:ok, mask_key, rest} ->
            cond do
              control?(opcode) and ext_len > 125 ->
                {:error, :control_frame_too_large}

              control?(opcode) and fin == 0 ->
                {:error, :fragmented_control_frame}

              true ->
                {:ok, %{fin: fin == 1, opcode: opcode, mask_key: mask_key, len: ext_len}, rest}
            end

          :short ->
            {:error, :short_frame}
        end

      :short ->
        {:error, :short_frame}
    end
  end

  defp check_rsv(0), do: :ok
  defp check_rsv(_), do: {:error, :rsv_set}

  defp check_mask(0), do: :ok
  defp check_mask(1), do: {:error, :masked_server_frame}

  defp check_mask_server(1), do: :ok
  defp check_mask_server(0), do: {:error, :unmasked_client_frame}

  defp extended_length(126, <<len::16, rest::binary>>), do: {:ok, len, rest}
  defp extended_length(127, <<len::64, rest::binary>>), do: {:ok, len, rest}
  defp extended_length(126, _rest), do: :short
  defp extended_length(127, _rest), do: :short
  defp extended_length(len, rest), do: {:ok, len, rest}

  defp take_mask(0, rest), do: {:ok, nil, rest}

  defp take_mask(1, <<mask::binary-4, rest::binary>>), do: {:ok, mask, rest}
  defp take_mask(1, _rest), do: :short

  defp control?(opcode), do: opcode >= 0x8

  # {frames acc, fragment acc} — the fragment acc is
  #   []                                        no in-flight fragmented message
  #   {opcode, payload, raw}                    an in-flight fragmented message
  # where `raw` is the RAW buffer bytes consumed by the fragment so far —
  # an incomplete fragment at the buffer end is re-emitted into `rest` so
  # the caller accumulates (`rest <> new_data`) and re-decodes (H1's
  # sibling discipline on the frame stream).
  defp do_decode(<<>>, frames, frag, _mode),
    do: {:ok, Enum.reverse(frames), frag_rest(frag)}

  defp do_decode(buffer, frames, frag, mode) do
    case parse(buffer, mode) do
      {:ok, header, rest} ->
        case take_payload(header, rest) do
          {:ok, payload, rest2} ->
            raw = raw_span(buffer, rest2)

            case classify(header, payload, frag) do
              {:ok, :emit, frame} ->
                do_decode(rest2, [frame | frames], [], mode)

              {:ok, :fragment, {opcode, payload}} ->
                do_decode(rest2, frames, {opcode, payload, raw}, mode)

              {:ok, :continue, {opcode, payload}} ->
                do_decode(rest2, frames, {opcode, payload, frag_raw(frag) <> raw}, mode)

              {:error, reason} ->
                {:error, reason}
            end

          {:error, :short_frame} ->
            {:ok, Enum.reverse(frames), frag_rest(frag) <> buffer}
        end

      {:error, :short_frame} ->
        {:ok, Enum.reverse(frames), frag_rest(frag) <> buffer}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp frag_rest([]), do: <<>>
  defp frag_rest({_opcode, _payload, raw}), do: raw

  defp frag_raw([]), do: <<>>
  defp frag_raw({_opcode, _payload, raw}), do: raw

  # the raw bytes of the frame just parsed: everything from the buffer start
  # through the payload end
  defp raw_span(buffer, rest), do: binary_part(buffer, 0, byte_size(buffer) - byte_size(rest))

  defp parse(buffer, :reject), do: parse_header(buffer)
  defp parse(buffer, :expect), do: parse_header_server(buffer)

  defp take_payload(%{len: len, mask_key: nil}, rest) do
    case rest do
      <<payload::binary-size(len), rest::binary>> -> {:ok, payload, rest}
      _short -> {:error, :short_frame}
    end
  end

  defp take_payload(%{len: len, mask_key: key}, rest) do
    case rest do
      <<masked::binary-size(len), rest::binary>> ->
        {:ok, unmask(masked, key), rest}

      _short ->
        {:error, :short_frame}
    end
  end

  defp unmask(masked, <<a, b, c, d>>) do
    masked
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.map(fn {byte, i} ->
      key =
        case rem(i, 4) do
          0 -> a
          1 -> b
          2 -> c
          3 -> d
        end

      Bitwise.bxor(byte, key)
    end)
    |> :binary.list_to_bin()
  end

  # classify one parsed frame against the fragment state
  defp classify(%{fin: true, opcode: opcode}, payload, [])
       when opcode != @opcode_continuation,
       do: {:ok, :emit, {opcode, payload}}

  defp classify(%{fin: false, opcode: opcode}, payload, [])
       when opcode == @opcode_text or opcode == @opcode_binary,
       do: {:ok, :fragment, {opcode, payload}}

  defp classify(%{fin: fin, opcode: @opcode_continuation}, payload, {opcode, acc, _raw}) do
    if fin do
      {:ok, :emit, {opcode, acc <> payload}}
    else
      {:ok, :continue, {opcode, acc <> payload}}
    end
  end

  defp classify(%{opcode: @opcode_continuation}, _payload, []),
    do: {:error, :continuation_without_fragment}

  defp classify(%{fin: false, opcode: opcode}, _payload, {_frag_op, _frag_payload, _raw}),
    do: {:error, {:data_frame_during_fragment, opcode}}

  defp classify(_header, _payload, _frag), do: {:error, :unexpected_frame}
end
