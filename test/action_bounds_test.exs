defmodule Kyber.Agent.ActionBoundsTest do
  @moduledoc """
  T12 AC3 — bounded by construction: path traversal outside the workspace
  root is refused (fs.read/fs.write/fs.list — the boundary is the action's
  expanded-path check, never a test-only assertion); shell runs have a hard
  timeout, a sandboxed cwd, a scrubbed environment, and a capped output
  with a truncation marker; HTTP bodies are capped and secret-free.
  """
  use ExUnit.Case, async: true

  alias Kyber.{Schema, Store, Wire}
  alias Kyber.Agent.{Action, ToolExecutor}
  alias Kyber.Agent.Action.Gate
  alias Kyber.Agent.Events, as: AgentEvents

  @agent_seed String.duplicate("b2", 32)
  @fixture_content "the oracle answer is 42"

  # the injected HTTP client for the action seam — never a real service
  defmodule StubActionHttp do
    @behaviour Kyber.Agent.HttpClient

    @impl true
    def get(url, _headers, state) do
      send(state.reply_to, {:http_get, url})
      respond(state)
    end

    @impl true
    def post(url, _headers, body, state) do
      send(state.reply_to, {:http_post, url, body})
      respond(state)
    end

    defp respond(%{error: reason}), do: {:error, reason}
    defp respond(state), do: {:ok, %{status: state.status, body: state.body}}
  end

  defp tmp_workspace do
    base = Path.join(System.tmp_dir!(), "kyber-t12-bounds-#{System.unique_integer([:positive])}")
    ws = Path.join(base, "workspace")
    File.mkdir_p!(ws)
    File.write!(Path.join(ws, "notes.txt"), @fixture_content)
    # planted OUTSIDE the workspace root — the traversal target
    File.write!(Path.join(base, "outside-secret.txt"), "must never leak")
    on_exit(fn -> File.rm_rf(base) end)
    {base, ws}
  end

  defp start_store, do: elem(Agent.start_link(fn -> %{} end), 1)

  # bounds tests allow-list everything under test; the gate's own boundary
  # is AC2's file
  defp run_action(store, context, tool_id, args, ts \\ 1_700_000_000_000.0) do
    {:ok, signed} =
      AgentEvents.tool_call(@agent_seed, ts, tool_id, args, String.duplicate("cd", 32))

    wire = Wire.envelope(signed)
    {:ok, call} = Store.verify(wire)

    handler =
      ToolExecutor.handler(
        seed: @agent_seed,
        tools: Action.registry(),
        gate: Gate.new(default: :allow),
        context: context,
        store: fn -> Agent.get(store, & &1) end
      )

    assert [_gate_wire, result_wire] = handler.([call])
    {:ok, result_delta} = Store.verify(result_wire)
    Schema.resolve(result_delta.claims)
  end

  # ------------------------------------------------------------------ tests

  test "AC3: fs.read refuses traversal outside the workspace root — by construction" do
    {_base, ws} = tmp_workspace()
    store = start_store()
    context = Action.context(workspace: ws)

    for escape <- ["../outside-secret.txt", "../../etc/hostname", "/etc/hostname"] do
      result = run_action(store, context, "fs.read", JSON.encode!(%{"path" => escape}))
      assert result.status == "refused"
      assert result.result =~ "escapes the workspace root"
      refute result.result =~ "must never leak"
    end

    # a syntactic .. that resolves back INSIDE the root is not an escape
    inside = run_action(store, context, "fs.read", JSON.encode!(%{"path" => "sub/../notes.txt"}))
    assert inside.status == "ok"
    assert inside.result == @fixture_content
  end

  test "AC3: fs.write and fs.list refuse escapes; the refused write never happens" do
    {base, ws} = tmp_workspace()
    store = start_store()
    context = Action.context(workspace: ws)

    written =
      run_action(
        store,
        context,
        "fs.write",
        JSON.encode!(%{"path" => "../escaped.txt", "content" => "nope"})
      )

    assert written.status == "refused"
    refute File.exists?(Path.join(base, "escaped.txt"))

    listed = run_action(store, context, "fs.list", JSON.encode!(%{"path" => ".."}))
    assert listed.status == "refused"
    refute listed.result =~ "outside-secret.txt"
  end

  test "AC3: fs.write is create-or-update under the root, attested; a read of a missing file is a recorded error" do
    {_base, ws} = tmp_workspace()
    store = start_store()
    context = Action.context(workspace: ws)

    created =
      run_action(
        store,
        context,
        "fs.write",
        JSON.encode!(%{"path" => "deep/nested/new.txt", "content" => "fresh"})
      )

    assert created.status == "ok"
    assert File.read!(Path.join(ws, "deep/nested/new.txt")) == "fresh"

    updated =
      run_action(
        store,
        context,
        "fs.write",
        JSON.encode!(%{"path" => "deep/nested/new.txt", "content" => "revised"}),
        1_700_000_000_001.0
      )

    assert updated.status == "ok"
    assert File.read!(Path.join(ws, "deep/nested/new.txt")) == "revised"

    missing =
      run_action(
        store,
        context,
        "fs.read",
        JSON.encode!(%{"path" => "nope.txt"}),
        1_700_000_000_002.0
      )

    assert missing.status == "error"
    assert missing.result =~ "nope.txt"
  end

  test "AC3: sh.run is sandboxed to the workspace cwd with a scrubbed environment" do
    {_base, ws} = tmp_workspace()
    store = start_store()
    context = Action.context(workspace: ws)
    System.put_env("KYBER_T12_SECRET_MARKER", "hunter2")
    on_exit(fn -> System.delete_env("KYBER_T12_SECRET_MARKER") end)

    pwd = run_action(store, context, "sh.run", JSON.encode!(%{"command" => "pwd"}))
    assert pwd.status == "ok"
    assert String.trim(pwd.result) == Path.expand(ws)

    env =
      run_action(
        store,
        context,
        "sh.run",
        JSON.encode!(%{"command" => "env"}),
        1_700_000_000_001.0
      )

    assert env.status == "ok"
    assert env.result =~ "PATH="
    refute env.result =~ "KYBER_T12_SECRET_MARKER"
    refute env.result =~ "hunter2"
  end

  test "AC3: a symlink inside the workspace pointing outside cannot smuggle a read (fold: C's realpath containment)" do
    {_base, ws} = tmp_workspace()
    store = start_store()
    context = Action.context(workspace: ws)
    File.write!(Path.join(ws, "ok.txt"), "inside")

    outside = Path.join(System.tmp_dir!(), "kyber-outside-#{System.unique_integer([:positive])}")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "secret.txt"), "secret")
    File.ln_s!(outside, Path.join(ws, "evil"))
    on_exit(fn -> File.rm_rf(outside) end)

    smuggled = run_action(store, context, "fs.read", JSON.encode!(%{"path" => "evil/secret.txt"}))
    assert smuggled.status == "refused"

    # the construction does not over-refuse: an in-root read still works
    ok = run_action(store, context, "fs.read", JSON.encode!(%{"path" => "ok.txt"}))
    assert ok.status == "ok"
    assert ok.result == "inside"
  end

  test "AC3: a shell run hitting the hard timeout is killed and yields a timeout ToolResult" do
    {_base, ws} = tmp_workspace()
    store = start_store()
    context = %{Action.context(workspace: ws) | shell_timeout: 50}

    started = System.monotonic_time(:millisecond)
    result = run_action(store, context, "sh.run", JSON.encode!(%{"command" => "sleep 30"}))
    elapsed = System.monotonic_time(:millisecond) - started

    assert result.status == "timeout"
    assert result.result =~ Action.Shell.timeout_marker(50)
    # the hard kill: nowhere near the command's own 30 seconds
    assert elapsed < 10_000
    # the OS process group is actually dead (fold: A's SIGKILL, hardened to a
    # group kill — the port child is a group leader, so -os_pid kills sh AND
    # its children). Poll: SIGKILL'd processes linger as zombies until init
    # reaps them, so a bounded explicit-state-poll (subprocess sleep, never
    # Process.sleep) until pgrep finds nothing
    {_out, pgrep_exit} = poll_dead("^sleep 30$", 25)
    assert pgrep_exit == 1
  end

  # bounded poll for a process pattern to disappear — the no-sleep sanctioned
  # pattern: subprocess sleep between checks, hard cap, never Process.sleep
  defp poll_dead(pattern, tries) do
    {_out, code} = System.cmd("pgrep", ["-f", pattern])

    cond do
      code == 1 ->
        {_out, code}

      tries == 0 ->
        {_out, code}

      true ->
        System.cmd("sleep", ["0.1"])
        poll_dead(pattern, tries - 1)
    end
  end

  test "AC3: shell output is capped with a truncation marker — never silent" do
    {_base, ws} = tmp_workspace()
    store = start_store()
    context = %{Action.context(workspace: ws) | output_cap: 1024}

    big = run_action(store, context, "sh.run", JSON.encode!(%{"command" => "seq 1 100000"}))
    assert big.status == "ok"
    assert big.result =~ Action.truncation_marker(1024)
    assert byte_size(big.result) == 1024 + 1 + byte_size(Action.truncation_marker(1024))

    small =
      run_action(
        store,
        context,
        "sh.run",
        JSON.encode!(%{"command" => "echo small"}),
        1_700_000_000_001.0
      )

    assert small.status == "ok"
    assert small.result == "small\n"
    refute small.result =~ "truncated"
  end

  test "AC3: a non-zero exit is a ToolResult status, not a crash (stderr rides along)" do
    {_base, ws} = tmp_workspace()
    store = start_store()
    context = Action.context(workspace: ws)

    result =
      run_action(
        store,
        context,
        "sh.run",
        JSON.encode!(%{"command" => "echo out; echo err >&2; exit 3"})
      )

    assert result.status == "exit:3"
    assert result.result =~ "out"
    assert result.result =~ "err"
  end

  test "AC3: http response bodies are capped with the marker; request bodies over the cap are refused" do
    {_base, ws} = tmp_workspace()
    store = start_store()
    big_body = String.duplicate("x", 5_000)

    context = %{
      Action.context(
        workspace: ws,
        http: {StubActionHttp, %{reply_to: self(), status: 200, body: big_body}}
      )
      | output_cap: 1024
    }

    got =
      run_action(
        store,
        context,
        "http.get",
        JSON.encode!(%{"url" => "https://example.test/data"})
      )

    assert got.status == "ok"
    assert got.result =~ Action.truncation_marker(1024)
    assert byte_size(got.result) == 1024 + 1 + byte_size(Action.truncation_marker(1024))
    assert_received {:http_get, "https://example.test/data"}

    # a POST body over the cap is refused — a payload is never silently truncated
    refused =
      run_action(
        store,
        context,
        "http.post",
        JSON.encode!(%{
          "url" => "https://example.test/up",
          "body" => String.duplicate("y", 5_000)
        }),
        1_700_000_000_001.0
      )

    assert refused.status == "refused"
    assert refused.result =~ "exceeds the 1024-byte cap"
    refute_received {:http_post, _, _}
  end

  test "AC3: http refuses non-http schemes and credentialed URLs (no secrets in payloads)" do
    {_base, ws} = tmp_workspace()
    store = start_store()

    context =
      Action.context(
        workspace: ws,
        http: {StubActionHttp, %{reply_to: self(), status: 200, body: "ok"}}
      )

    for url <- [
          "file:///etc/hostname",
          "gopher://example.test/",
          "https://user:pass@example.test/"
        ] do
      result = run_action(store, context, "http.get", JSON.encode!(%{"url" => url}))
      assert result.status == "refused"
    end

    refute_received {:http_get, _}
  end

  test "AC3: http non-2xx and transport failures are recorded statuses, never crashes" do
    {_base, ws} = tmp_workspace()
    store = start_store()

    failing = %{
      reply_to: self(),
      status: 500,
      body: "server exploded"
    }

    context = Action.context(workspace: ws, http: {StubActionHttp, failing})

    result =
      run_action(
        store,
        context,
        "http.get",
        JSON.encode!(%{"url" => "https://example.test/oops"})
      )

    assert result.status == "http:500"
    assert result.result == "server exploded"

    transport =
      Action.context(
        workspace: ws,
        http: {StubActionHttp, %{reply_to: self(), error: :econnrefused}}
      )

    failed =
      run_action(
        store,
        transport,
        "http.get",
        JSON.encode!(%{"url" => "https://example.test/down"}),
        1_700_000_000_001.0
      )

    assert failed.status == "error"
    assert failed.result =~ "econnrefused"
  end
end
