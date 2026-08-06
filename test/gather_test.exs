defmodule Kyber.GatherTest do
  use ExUnit.Case, async: false

  alias Kyber.{Gather, Keys, Wire}
  alias Rhizomatic.Delta

  @agent_seed String.duplicate("ab", 32)

  setup do
    start_supervised!(Kyber.Gather)
    :ok
  end

  # ---------------------------------------------------------------- fixtures

  defp claims(pointers, ts) do
    raw = %{timestamp: ts, author: Keys.author_for_seed(@agent_seed), pointers: pointers}
    {:ok, validated} = Delta.validate(raw)
    validated
  end

  defp delta(pointers, ts \\ 1_754_512_345_678.0) do
    c = claims(pointers, ts)
    %{id: Delta.id_hex(c), claims: c}
  end

  defp signed_wire(pointers, ts \\ 1_754_512_345_678.0) do
    c = claims(pointers, ts)
    {:ok, sig} = Keys.sign(c, @agent_seed)
    Wire.envelope({c, sig})
  end

  defp tick_pointers do
    [%{role: "tick", target: {:entity, "cron:daemon-ticker", "fired"}}]
  end

  defp note_pointers(text) do
    [%{role: "note", target: {:string, text}}]
  end

  # ------------------------------------------------------------ subscription

  test "a handler subscribed by role fires on the matching delta with its saturated view" do
    test_pid = self()

    {:ok, _ref} =
      Gather.subscribe("note", fn view ->
        send(test_pid, {:fired, view})
        []
      end)

    d = delta(note_pointers("hello"))
    assert {:ok, %{fired: 1, outputs: [], errors: []}} = Gather.route(d)
    assert_receive {:fired, [^d]}
  end

  test "a non-matching role accumulates nothing and fires nothing" do
    test_pid = self()

    {:ok, _ref} =
      Gather.subscribe("note", fn view ->
        send(test_pid, {:fired, view})
        []
      end)

    assert {:ok, %{fired: 0, outputs: [], errors: []}} = Gather.route(delta(tick_pointers()))
    refute_received {:fired, _}
  end

  test "the view drops after firing — the next match fires a fresh single-delta view" do
    test_pid = self()

    {:ok, _ref} =
      Gather.subscribe("note", fn view ->
        send(test_pid, {:fired, view})
        []
      end)

    d1 = delta(note_pointers("one"))
    d2 = delta(note_pointers("two"))
    assert {:ok, %{fired: 1}} = Gather.route(d1)
    assert {:ok, %{fired: 1}} = Gather.route(d2)
    assert_receive {:fired, [^d1]}
    assert_receive {:fired, [^d2]}
  end

  test "outputs from every fired handler are collected in subscription order" do
    w1 = signed_wire(note_pointers("out-one"))
    w2 = signed_wire(note_pointers("out-two"))

    {:ok, _} = Gather.subscribe("note", fn _view -> [w1] end)
    {:ok, _} = Gather.subscribe("note", fn _view -> [w2] end)

    assert {:ok, %{fired: 2, outputs: [^w1, ^w2], errors: []}} =
             Gather.route(delta(note_pointers("in")))
  end

  test "routing matches on the FIRST pointer's role only (the template's kind marker)" do
    test_pid = self()

    {:ok, _ref} =
      Gather.subscribe("note", fn view ->
        send(test_pid, {:fired, view})
        []
      end)

    # "note" appears as a later pointer, but the kind marker is the first role
    mixed =
      delta([
        %{role: "tick", target: {:entity, "cron:daemon-ticker", "fired"}},
        %{role: "note", target: {:string, "buried"}}
      ])

    assert {:ok, %{fired: 0}} = Gather.route(mixed)
    refute_received {:fired, _}
  end

  test "a crashing handler does not kill the gather and contributes no outputs" do
    {:ok, _} = Gather.subscribe("note", fn _view -> raise "boom" end)

    assert {:ok, %{fired: 0, outputs: [], errors: [{:handler_crashed, _}]}} =
             Gather.route(delta(note_pointers("in")))

    # the gather survives and keeps routing
    assert {:ok, %{fired: 0, outputs: [], errors: [_]}} = Gather.route(delta(note_pointers("x")))
  end

  test "a handler returning a non-list is an error, never a crash" do
    {:ok, _} = Gather.subscribe("note", fn _view -> :not_a_list end)

    assert {:ok, %{fired: 0, outputs: [], errors: [:handler_output_not_a_list]}} =
             Gather.route(delta(note_pointers("in")))
  end

  # ----------------------------------------------------------------- notify

  test "notify: a door-valid pulse routes and returns the fired outputs to the caller" do
    test_pid = self()
    out = signed_wire(note_pointers("pulse reply"))

    {:ok, _ref} =
      Gather.subscribe("tick", fn [d] ->
        send(test_pid, {:tick_fired, d.id})
        [out]
      end)

    wire = signed_wire(tick_pointers())
    assert {:ok, [^out]} = Gather.notify(wire)
    assert_receive {:tick_fired, _id}
  end

  test "notify refuses at the door: an unsigned pulse never routes" do
    test_pid = self()

    {:ok, _ref} =
      Gather.subscribe("tick", fn view ->
        send(test_pid, {:tick_fired, view})
        []
      end)

    unsigned = Map.delete(signed_wire(tick_pointers()), "sig")
    assert {:error, :unsigned} = Gather.notify(unsigned)
    refute_received {:tick_fired, _}
  end

  test "notify refuses at the door: an id mismatch never routes" do
    wire = signed_wire(tick_pointers())
    forged = Map.put(wire, "id", String.duplicate("0", 68))
    assert {:error, :id_mismatch} = Gather.notify(forged)
  end
end
