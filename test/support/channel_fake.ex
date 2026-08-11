defmodule Kyber.Channel.Test.FakeTransport do
  @moduledoc """
  The frame-stream fake (T14i AC2/H4): a simulated Discord gateway over the
  transport seam. It behaves like the live gateway at the protocol level the
  adapter cares about — on `connect` it sends a hello (op 10) to the owner,
  on an op-2 identify it replies a READY dispatch, on an op-1 heartbeat it
  replies a heartbeat_ack (op 11), and it auto-pongs WS ping frames (the
  transport impl's pinned auto-pong — the frame-stream fake observes pongs,
  which is exactly why the sends-equal-ResponseDelta witness scopes to the
  delivery seam). The test drives it through `inject_message/2` and reads
  its recorded sends through `sends/1`.

  The fake is the TRANSPORT IMPL in tests: the adapter's `{module, state}`
  injection carries `%{fake: pid}`, and `connect/2` registers the adapter
  as the owner with the pre-started fake process.
  """

  use GenServer

  @behaviour Kyber.Channel.Transport

  # ------------------------------------------------------------------ API

  @doc "Start the fake gateway harness."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "The frames the fake has received from the adapter (raw JSON payload binaries)."
  @spec sends(pid()) :: [binary()]
  def sends(pid), do: GenServer.call(pid, :sends)

  @doc "Has the adapter identified yet (op 2 seen)?"
  @spec identified?(pid()) :: boolean()
  def identified?(pid), do: GenServer.call(pid, :identified?)

  @doc "How many op-2 identifies has the fake observed? (a restart re-identifies — the count distinguishes the FIRST from a re-connect)"
  @spec identify_count(pid()) :: non_neg_integer()
  def identify_count(pid), do: GenServer.call(pid, :identify_count)

  @doc "Inject a MESSAGE_CREATE dispatch (a Discord message map) to the owner."
  @spec inject_message(pid(), map()) :: :ok
  def inject_message(pid, msg), do: GenServer.call(pid, {:inject, :message_create, msg})

  @doc "Inject a raw gateway payload map to the owner."
  @spec inject(pid(), map()) :: :ok
  def inject(pid, payload), do: GenServer.call(pid, {:inject, :raw, payload})

  @doc "Close the connection (the adapter observes the close and reconnects)."
  @spec close_connection(pid()) :: :ok
  def close_connection(pid), do: GenServer.call(pid, :close_connection)

  # ------------------------------------------------------- the behaviour

  @impl true
  def connect(opts, owner_pid) do
    pid = Keyword.fetch!(opts, :state).fake
    GenServer.call(pid, {:connected, owner_pid})
    {:ok, pid}
  end

  @impl true
  def send_frame(pid, payload), do: GenServer.call(pid, {:send_frame, payload})

  @impl true
  def close(pid) do
    if Process.alive?(pid), do: GenServer.call(pid, :close)
    :ok
  end

  # ------------------------------------------------------------ callbacks

  @impl true
  def init(opts) do
    {:ok,
     %{
       owner: nil,
       sends: [],
       server: Keyword.get(opts, :server, "999"),
       interval: Keyword.get(opts, :heartbeat_interval, 5_000),
       seq: 100
     }}
  end

  @impl true
  def handle_call({:connected, owner}, _from, state) do
    hello = %{
      "op" => 10,
      "d" => %{
        "heartbeat_interval" => state.interval,
        "resume_gateway_url" => "ws://fake-gateway/resume"
      }
    }

    send(owner, {self(), {:frame, 0x1, JSON.encode!(hello)}})
    {:reply, :ok, %{state | owner: owner}}
  end

  def handle_call({:send_frame, payload}, _from, state) do
    state = %{state | sends: state.sends ++ [payload]}

    case JSON.decode(payload) do
      {:ok, %{"op" => 2}} ->
        send_ready(state)
        {:reply, :ok, state}

      {:ok, %{"op" => 1}} ->
        send(state.owner, {self(), {:frame, 0x1, JSON.encode!(%{"op" => 11, "d" => nil})}})
        {:reply, :ok, state}

      {:ok, %{"op" => 6}} ->
        # resume: accept and reply a resumed READY
        send_ready(state)
        {:reply, :ok, state}

      _other ->
        {:reply, :ok, state}
    end
  end

  def handle_call(:sends, _from, state), do: {:reply, state.sends, state}

  def handle_call(:identified?, _from, state) do
    {:reply,
     Enum.any?(state.sends, fn payload ->
       match?({:ok, %{"op" => 2}}, JSON.decode(payload))
     end), state}
  end

  def handle_call(:identify_count, _from, state) do
    count =
      Enum.count(state.sends, fn payload ->
        match?({:ok, %{"op" => 2}}, JSON.decode(payload))
      end)

    {:reply, count, state}
  end

  def handle_call({:inject, kind, msg}, _from, state) do
    payload =
      case kind do
        :message_create ->
          state = %{state | seq: state.seq + 1}

          %{
            "op" => 0,
            "t" => "MESSAGE_CREATE",
            "s" => state.seq,
            "d" => msg
          }

        :raw ->
          msg
      end

    send(state.owner, {self(), {:frame, 0x1, JSON.encode!(payload)}})
    {:reply, :ok, state}
  end

  def handle_call(:close_connection, _from, state) do
    if state.owner, do: send(state.owner, {self(), {:frame, 0x8, ""}})
    {:reply, :ok, state}
  end

  def handle_call(:close, _from, state), do: {:reply, :ok, state}

  # the pinned transport-impl auto-pong: a ping frame is answered internally,
  # never forwarded to the owner (M3 — the pure codec cannot send)
  @impl true
  def handle_info({:ping, payload}, state) do
    send(state.owner, {self(), {:frame, 0xA, payload}})
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp send_ready(state) do
    payload = %{
      "op" => 0,
      "t" => "READY",
      "s" => state.seq + 1,
      "d" => %{
        "session_id" => "fake-session-1",
        "user" => %{"id" => "bot-self-id"}
      }
    }

    send(state.owner, {self(), {:frame, 0x1, JSON.encode!(payload)}})
  end
end

defmodule Kyber.Channel.Test.FakeDelivery do
  @moduledoc """
  The delivery-seam fake (T14i H4): records every REST-shaped delivery call
  (url/headers/body) and answers a 200. The sends-equal-ResponseDelta
  witness scopes to THIS seam — the frame-stream fake is never held to that
  equality (heartbeats/pongs break it, M3).
  """

  use GenServer

  @behaviour Kyber.Channel.Delivery

  @doc "Start the fake delivery harness."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "The recorded deliveries: `[{url, headers, body}]` in order."
  @spec posts(pid()) :: [{String.t(), [{String.t(), String.t()}], binary()}]
  def posts(pid), do: GenServer.call(pid, :posts)

  # ------------------------------------------------------- the behaviour

  @impl true
  def post(url, headers, body, %{pid: pid}) do
    GenServer.call(pid, {:post, url, headers, body})
  end

  # ------------------------------------------------------------ callbacks

  @impl true
  def init(_opts), do: {:ok, %{posts: []}}

  @impl true
  def handle_call({:post, url, headers, body}, _from, state) do
    {:reply, {:ok, %{status: 200, body: "{}"}}, %{state | posts: state.posts ++ [{url, headers, body}]}}
  end

  def handle_call(:posts, _from, state), do: {:reply, state.posts, state}
end
