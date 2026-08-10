defmodule Kyber.Agent.ToolBoundsTest do
  @moduledoc """
  T14d AC2 — tool bounds: every Class B cap pinned to an exact value with an
  exact behavior + a deterministic test at and past the cap. Fails-when-
  absent: removing a cap or its leg fails the suite.

  The pinned caps (the T14d diff metric): fs.read 65_536 bytes via the
  context's :output_cap (executor clause, tests inject 1024); fs.list 1024
  entries (the ONE new literal, ToolExecutor home, count-worded marker);
  shell containment = exactly four bounds (cwd sandbox, env scrubbed to
  exactly PATH/HOME/TMPDIR, 5_000 ms hard tree-kill, output cap with
  marker) with fs-escape running as the DECLARED HOLE; http.get/post
  65_536 body cap with POST over-cap REFUSED (never truncated), GET
  30_000 / POST 120_000 / connect 10_000 pinned by a STATIC option-list
  witness; timeout -> "error" via inspect(reason).
  """
  use ExUnit.Case, async: true

  alias Kyber.{Schema, Store, Wire}
  alias Kyber.Agent.{Action, Events, ToolExecutor}
  alias Kyber.Agent.Action.Gate
  alias Kyber.Agent.Events, as: AgentEvents
  alias Rhizomatic.Delta

  @agent_seed String.duplicate("b2", 32)
  @ts 1_700_000_000_000.0
  @fs_list_marker "[truncated: listing exceeded the 1024-entry cap]"

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
    base = Path.join(System.tmp_dir!(), "kyber-t14d-bounds-#{System.unique_integer([:positive])}")
    ws = Path.join(base, "workspace")
    File.mkdir_p!(ws)
    on_exit(fn -> File.rm_rf(base) end)
    {base, ws}
  end

  defp start_store, do: elem(Agent.start_link(fn -> %{} end), 1)

  # T14e: the http bounds tests exercise the ACTION layer — the E2 closure
  # refuses ungoverned url calls at the gate, so every http test's store is
  # GOVERNED with a url_policy epoch allow-listing exactly its test URLs
  # (the closure's blast radius is governed-calls-still-execute, A13b)
  defp seed_epoch(hosts, schemes) do
    {:ok, {claims, sig}} =
      AgentEvents.policy(@agent_seed, @ts, "url_policy", hosts, schemes)

    {Delta.id_hex(claims), {claims, sig}}
  end

  defp run_action(store, context, tool_id, args, ts \\ @ts) do
    {:ok, signed} = AgentEvents.tool_call(@agent_seed, ts, tool_id, args, String.duplicate("cd", 32))
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

  defp run_memory_action(store, tool_id, args) do
    {:ok, signed} = AgentEvents.tool_call(@agent_seed, @ts, tool_id, args, String.duplicate("cd", 32))
    wire = Wire.envelope(signed)
    {:ok, call} = Store.verify(wire)

    handler =
      ToolExecutor.handler(
        seed: @agent_seed,
        tools: ToolExecutor.memory_tools(fn -> Agent.get(store, & &1) end),
        gate: Gate.new(default: :allow),
        store: fn -> Agent.get(store, & &1) end
      )

    handler.([call])
  end

  # ------------------------------------------------------------- B1 (D6)

  # B1 — fs.read output cap: 65_536 via the context's :output_cap
  # (action.ex's @default_output_cap is the ONE home; tests inject 1024).
  # Past-cap: binary_part(content, 0, cap) <> "\n" <> marker, status "ok";
  # at exactly cap: untruncated, NO marker; a refusal is NEVER truncated.
  test "B1: fs.read past-cap truncates with the house newline joiner + marker, status ok" do
    {_base, ws} = tmp_workspace()
    big = String.duplicate("x", 2_000)
    File.write!(Path.join(ws, "big.txt"), big)
    store = start_store()
    context = %{Action.context(workspace: ws) | output_cap: 1024}

    result = run_action(store, context, "fs.read", JSON.encode!(%{"path" => "big.txt"}))

    assert result.status == "ok"
    assert result.result ==
             binary_part(big, 0, 1024) <> "\n" <> Action.truncation_marker(1024)
    assert byte_size(result.result) == 1024 + 1 + byte_size(Action.truncation_marker(1024))
  end

  test "B1: fs.read at exactly the cap — untruncated, NO marker" do
    {_base, ws} = tmp_workspace()
    exact = String.duplicate("y", 1024)
    File.write!(Path.join(ws, "exact.txt"), exact)
    store = start_store()
    context = %{Action.context(workspace: ws) | output_cap: 1024}

    result = run_action(store, context, "fs.read", JSON.encode!(%{"path" => "exact.txt"}))

    assert result.status == "ok"
    assert result.result == exact
    refute result.result =~ "truncated"
  end

  test "B1: fs.read under the cap — untouched" do
    {_base, ws} = tmp_workspace()
    File.write!(Path.join(ws, "small.txt"), "small")
    store = start_store()
    context = %{Action.context(workspace: ws) | output_cap: 1024}

    result = run_action(store, context, "fs.read", JSON.encode!(%{"path" => "small.txt"}))

    assert result.status == "ok"
    assert result.result == "small"
    refute result.result =~ "truncated"
  end

  test "B1: a refusal is NEVER truncated — the pinned refusal spelling survives verbatim" do
    {_base, ws} = tmp_workspace()
    store = start_store()
    # a cap far below the refusal's own length: truncation would destroy it
    context = %{Action.context(workspace: ws) | output_cap: 8}

    result =
      run_action(store, context, "fs.read", JSON.encode!(%{"path" => "../outside-secret.txt"}))

    assert result.status == "refused"
    assert result.result == "refused: ../outside-secret.txt escapes the workspace root"
  end

  # ------------------------------------------------------------- B2 (D7)

  # B2 — fs.list entry cap: 1024 (the ONE new literal, ToolExecutor home),
  # first 1024 of the SORTED listing + the count-worded marker, status
  # "ok". Test seam: hardcoded fixture dirs (context injection is
  # UNLICENSED for the entry cap).
  # the fixture directory lives INSIDE the workspace root — fs.list is
  # bound to the root, and the absolute-path escape is refused by
  # construction (the seam: hardcoded entry counts, context injection is
  # UNLICENSED for the entry cap)
  defp fixture_dir(ws, entries) do
    dir = Path.join(ws, "fixture-#{entries}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    for i <- 1..entries do
      name = "f" <> String.pad_leading(Integer.to_string(i), 5, "0")
      File.write!(Path.join(dir, name), "x")
    end

    dir
  end

  defp list_result(ws, dir) do
    store = start_store()
    context = Action.context(workspace: ws)
    run_action(store, context, "fs.list", JSON.encode!(%{"path" => Path.relative_to(dir, ws)}), @ts + 1)
  end

  test "B2: fs.list at 1024 entries — full listing, NO marker" do
    {_base, ws} = tmp_workspace()
    dir = fixture_dir(ws, 1024)
    result = list_result(ws, dir)

    assert result.status == "ok"
    assert length(String.split(result.result, "\n")) == 1024
    refute result.result =~ "truncated"
    assert result.result =~ "f00001"
    assert result.result =~ "f01024"
  end

  test "B2: fs.list at 1025 entries — first 1024 of the sorted listing + the count-worded marker" do
    {_base, ws} = tmp_workspace()
    dir = fixture_dir(ws, 1025)
    result = list_result(ws, dir)

    assert result.status == "ok"
    assert String.ends_with?(result.result, @fs_list_marker)
    assert result.result =~ "\n" <> @fs_list_marker
    # 1024 kept entries + the marker line
    assert length(String.split(result.result, "\n")) == 1025
    # sorted prefix: the smallest name rides first, the 1025th is dropped
    assert String.starts_with?(result.result, "f00001")
    assert result.result =~ "f01024"
    refute result.result =~ "f01025"
  end

  test "B2: the newline-in-filename edge is RECORDED, not handled — a name with \\n breaks the line grammar" do
    {_base, ws} = tmp_workspace()
    dir = fixture_dir(ws, 2)
    File.write!(Path.join(dir, "a\nb"), "x")
    result = list_result(ws, dir)

    # the entry counts as TWO lines in the listing grammar (the marker logic
    # splits on \n) — recorded, never handled (a fix is a visible diff)
    assert result.status == "ok"
    assert length(String.split(result.result, "\n")) ==
             length(File.ls!(dir)) + 1
  end

  # ------------------------------------------------------------- B3 (D8)

  # B3 — shell containment: EXACTLY four bounds. (1) cwd sandboxed to the
  # workspace root; (2) env scrubbed to exactly PATH/HOME/TMPDIR; (3)
  # 5_000 ms hard tree-kill; (4) output cap with marker.
  test "B3: bound 1 — the shell cwd is sandboxed to the workspace root" do
    {_base, ws} = tmp_workspace()
    store = start_store()
    context = Action.context(workspace: ws)

    pwd = run_action(store, context, "sh.run", JSON.encode!(%{"command" => "pwd"}))

    assert pwd.status == "ok"
    assert String.trim(pwd.result) == Path.expand(ws)
  end

  test "B3: bound 2 — the env is scrubbed to EXACTLY PATH/HOME/TMPDIR" do
    {_base, ws} = tmp_workspace()
    store = start_store()
    context = Action.context(workspace: ws)
    System.put_env("KYBER_T14D_SECRET_MARKER", "hunter2")
    on_exit(fn -> System.delete_env("KYBER_T14D_SECRET_MARKER") end)

    env = run_action(store, context, "sh.run", JSON.encode!(%{"command" => "env"}))

    assert env.status == "ok"
    lines = String.split(String.trim(env.result), "\n")
    # the scrubbed env grants EXACTLY PATH/HOME/TMPDIR (the kept set,
    # shell.ex:179-192); the shell ITSELF injects PWD at startup —
    # deterministic, bounded to the sandboxed cwd (PWD == HOME == the
    # workspace root), never an inherited variable
    assert length(lines) == 4
    assert Enum.all?(lines, &(&1 =~ ~r/^(PATH|HOME|TMPDIR|PWD)=/))
    assert Enum.any?(lines, &(&1 == "HOME=" <> Path.expand(ws)))
    assert Enum.any?(lines, &(&1 == "PWD=" <> Path.expand(ws)))
    assert Enum.any?(lines, &String.starts_with?(&1, "TMPDIR="))
    assert Enum.any?(lines, &String.starts_with?(&1, "PATH="))
    refute env.result =~ "KYBER_T14D_SECRET_MARKER"
    refute env.result =~ "hunter2"
  end

  test "B3: bound 3 — a run past the timeout is a hard tree-kill, never a hang" do
    {_base, ws} = tmp_workspace()
    store = start_store()
    context = %{Action.context(workspace: ws) | shell_timeout: 50}

    started = System.monotonic_time(:millisecond)
    result = run_action(store, context, "sh.run", JSON.encode!(%{"command" => "sleep 30"}))
    elapsed = System.monotonic_time(:millisecond) - started

    assert result.status == "timeout"
    assert result.result =~ Action.Shell.timeout_marker(50)
    assert elapsed < 10_000
  end

  test "B3: bound 4 — shell output is capped with the truncation marker, never silent" do
    {_base, ws} = tmp_workspace()
    store = start_store()
    context = %{Action.context(workspace: ws) | output_cap: 1024}

    big = run_action(store, context, "sh.run", JSON.encode!(%{"command" => "seq 1 100000"}))

    assert big.status == "ok"
    assert big.result =~ Action.truncation_marker(1024)
    assert byte_size(big.result) == 1024 + 1 + byte_size(Action.truncation_marker(1024))
  end

  # B3 — the fs-escape RUNS as the DECLARED HOLE: lexical command screening
  # is a placebo and is never the boundary; GOVERNANCE (the permission gate)
  # is the control. The escaped read returns "ok" WITH content, so later
  # closure is a visible diff.
  test "B3: fs-escape is the declared hole — an escaped read runs with content, governance is the control" do
    {base, ws} = tmp_workspace()
    secret = Path.join(base, "outside-secret.txt")
    File.write!(secret, "the escaped secret")
    store = start_store()
    context = Action.context(workspace: ws)

    result =
      run_action(
        store,
        context,
        "sh.run",
        JSON.encode!(%{"command" => "cat " <> secret}),
        @ts + 1
      )

    assert result.status == "ok"
    assert result.result =~ "the escaped secret"
  end

  # B3 — the fs refusal spelling is the EXISTING "refused: " <> path <>
  # " escapes the workspace root" (fs.ex), never a rebuild
  test "B3: the fs escape refusal — the existing spelling, by construction" do
    {base, ws} = tmp_workspace()
    File.write!(Path.join(base, "outside-secret.txt"), "must never leak")
    store = start_store()
    context = Action.context(workspace: ws)

    result =
      run_action(store, context, "fs.read", JSON.encode!(%{"path" => "../outside-secret.txt"}))

    assert result.status == "refused"
    assert result.result == "refused: ../outside-secret.txt escapes the workspace root"
  end

  # B3b/B3c — static default-value witnesses at their EFFECTIVE homes
  # (action.ex's @default_shell_timeout / @default_output_cap): the
  # shell-internal shadowed defaults (shell.ex:23-24) never fire via the
  # registry path, because Action.context always supplies the values.
  test "B3b/B3c: the 5_000 ms timeout and 65_536 output cap live at action.ex and ride Action.context" do
    source = File.read!("lib/kyber/agent/action.ex")
    assert source =~ "@default_shell_timeout 5_000"
    assert source =~ "@default_output_cap 65_536"

    ws = Path.join(System.tmp_dir!(), "kyber-t14d-b3-#{System.unique_integer([:positive])}")
    File.mkdir_p!(ws)
    on_exit(fn -> File.rm_rf(ws) end)

    context = Action.context(workspace: ws)
    assert context.shell_timeout == 5_000
    assert context.output_cap == 65_536
  end

  # ------------------------------------------------------------- B4 (D9)

  # B4 — the fetch surface is http.get/http.post: web_fetch is a PHANTOM
  # (defect S3 — the spec named a tool that does not exist; any future fetch
  # surface is a NEW slice)
  test "B4: web_fetch is a phantom — the registry surface is http.get/http.post" do
    registry = Action.registry()
    refute Map.has_key?(registry, "web_fetch")
    assert Map.has_key?(registry, "http.get")
    assert Map.has_key?(registry, "http.post")
  end

  test "B4: http response bodies are capped with the marker (65_536 by construction, injected 1024)" do
    {_base, ws} = tmp_workspace()
    store = start_store()
    {epoch_id, epoch} = seed_epoch(["example.test"], ["https"])
    Agent.update(store, &Map.put(&1, epoch_id, epoch))
    big_body = String.duplicate("x", 5_000)

    context = %{
      Action.context(
        workspace: ws,
        http: {StubActionHttp, %{reply_to: self(), status: 200, body: big_body}}
      )
      | output_cap: 1024
    }

    got = run_action(store, context, "http.get", JSON.encode!(%{"url" => "https://example.test/data"}))

    assert got.status == "ok"
    assert got.result =~ Action.truncation_marker(1024)
    assert byte_size(got.result) == 1024 + 1 + byte_size(Action.truncation_marker(1024))
    assert_received {:http_get, "https://example.test/data"}
  end

  test "B4: a POST body over the cap is REFUSED, never truncated, and never sent" do
    {_base, ws} = tmp_workspace()
    store = start_store()
    {epoch_id, epoch} = seed_epoch(["example.test"], ["https"])
    Agent.update(store, &Map.put(&1, epoch_id, epoch))

    context = %{
      Action.context(
        workspace: ws,
        http: {StubActionHttp, %{reply_to: self(), status: 200, body: "ok"}}
      )
      | output_cap: 1024
    }

    refused =
      run_action(
        store,
        context,
        "http.post",
        JSON.encode!(%{
          "url" => "https://example.test/up",
          "body" => String.duplicate("y", 5_000)
        }),
        @ts + 1
      )

    assert refused.status == "refused"
    assert refused.result =~ "exceeds the 1024-byte cap"
    # never truncated, never sent — the refusal is terminal
    refute_received {:http_post, _, _}
  end

  # B4 — the adapter timeouts pinned by a STATIC option-list witness (the
  # only deterministic form — no Process.sleep): GET 30_000 / POST 120_000 /
  # connect 10_000, both lists.
  test "B4: the adapter timeouts — GET 30_000 / POST 120_000 / connect 10_000 (static option-list witness)" do
    source = File.read!("lib/kyber/agent/http_client.ex")

    option_lists =
      Regex.scan(~r/http_options = \[(.*?)\]/s, source, capture: :all_but_first)

    assert length(option_lists) == 2
    [get_opts] = Enum.find(option_lists, fn [opts] -> opts =~ "timeout: 30_000" end)
    [post_opts] = Enum.find(option_lists, fn [opts] -> opts =~ "timeout: 120_000" end)

    assert get_opts =~ "timeout: 30_000"
    assert post_opts =~ "timeout: 120_000"
    for [opts] <- option_lists do
      assert opts =~ "connect_timeout: 10_000"
      assert opts =~ "autoredirect: false"
    end
  end

  # B4 — a timeout surfaces as "error" via inspect(reason): "http.get <url>:
  # :timeout" — the P2 spelling
  test "B4: a transport timeout maps via inspect(reason) to the http.<method> <url>: :timeout error" do
    {_base, ws} = tmp_workspace()
    store = start_store()
    {epoch_id, epoch} = seed_epoch(["example.test"], ["https"])
    Agent.update(store, &Map.put(&1, epoch_id, epoch))

    context =
      Action.context(
        workspace: ws,
        http: {StubActionHttp, %{reply_to: self(), error: :timeout}}
      )

    got = run_action(store, context, "http.get", JSON.encode!(%{"url" => "https://example.test/x"}))

    assert got.status == "error"
    assert got.result == "http.get https://example.test/x: :timeout"

    posted =
      run_action(
        store,
        context,
        "http.post",
        JSON.encode!(%{"url" => "https://example.test/x", "body" => "b"}),
        @ts + 1
      )

    assert posted.status == "error"
    assert posted.result == "http.post https://example.test/x: :timeout"
  end

  # B5 — autoredirect: false, both option lists (the T14b L4 witness, kept
  # in the matrix): a 3xx is a terminal ToolResult, never a followed
  # redirect (an ungated second request)
  test "B5: httpc never follows redirects — both option lists carry autoredirect: false" do
    source = File.read!("lib/kyber/agent/http_client.ex")

    option_lists =
      Regex.scan(~r/http_options = \[(.*?)\]/s, source, capture: :all_but_first)

    assert length(option_lists) == 2

    for [options] <- option_lists do
      assert options =~ "autoredirect: false"
    end
  end

  # ------------------------------------------------------------- B6/B7/B8

  # B6 — memory.read unknown entity: a well-formed string id with canon nil
  # resolves to {"", "unknown_entity"} — a resolution outcome, never a
  # refusal (the T14c taste cell, kept in the matrix)
  test ~s|B6: memory.read of an unknown entity — the pinned {"", "unknown_entity"} resolution| do
    store = start_store()
    {:ok, {epoch_claims, epoch_sig}} = Events.memory_policy(@agent_seed, @ts, ["ghost"])
    epoch_id = Rhizomatic.Delta.id_hex(epoch_claims)
    Agent.update(store, &Map.put(&1, epoch_id, {epoch_claims, epoch_sig}))

    [gate_wire, result_wire] =
      run_memory_action(store, "memory.read", JSON.encode!(%{"entity" => "ghost"}))

    {:ok, gate_delta} = Store.verify(gate_wire)
    assert Schema.resolve(gate_delta.claims).verdict == "allow"

    {:ok, result_delta} = Store.verify(result_wire)
    result = Schema.resolve(result_delta.claims)
    assert result.type == "ToolResult"
    # the pinned resolution: the RESULT is "" and the STATUS is
    # "unknown_entity" — a resolution outcome, never a refusal
    assert result.result == ""
    assert result.status == "unknown_entity"
  end

  # B7 — memory.read under a FORKED epoch: refuse-before-resolve (D3) —
  # Memory.canon NEVER runs, refused known/unknown are indistinguishable
  # (no existence oracle)
  test "B7: forked epoch x memory.read — refuse-before-resolve, known and unknown indistinguishable" do
    store = start_store()

    {:ok, {a_claims, a_sig}} = Events.memory_policy(@agent_seed, @ts, ["e-known"])
    {:ok, {b_claims, b_sig}} = Events.memory_policy(@agent_seed, @ts + 1, ["e-other"])
    a_id = Rhizomatic.Delta.id_hex(a_claims)
    b_id = Rhizomatic.Delta.id_hex(b_claims)

    {:ok, {mem_claims, mem_sig}} =
      Events.memory_entity(@agent_seed, @ts, "e-known", "classified sentinel", [])

    mem_id = Rhizomatic.Delta.id_hex(mem_claims)

    Agent.update(store, fn set ->
      set
      |> Map.put(a_id, {a_claims, a_sig})
      |> Map.put(b_id, {b_claims, b_sig})
      |> Map.put(mem_id, {mem_claims, mem_sig})
    end)

    known =
      run_memory_action(store, "memory.read", JSON.encode!(%{"entity" => "e-known"}))

    assert [known_refusal] = known
    {:ok, known_delta} = Store.verify(known_refusal)
    known_typed = Schema.resolve(known_delta.claims)
    assert known_typed.verdict == "refuse"
    assert known_typed.policy == "memory_policy"
    assert known_typed.reason == "memory_policy: epoch forked (fail closed)"
    assert known_typed.policy_epoch == nil

    unknown =
      run_memory_action(store, "memory.read", JSON.encode!(%{"entity" => "e-never-heard-of"}))

    assert [unknown_refusal] = unknown
    {:ok, unknown_delta} = Store.verify(unknown_refusal)
    unknown_typed = Schema.resolve(unknown_delta.claims)

    # SAME refusal — known and unknown are indistinguishable under fork
    assert unknown_typed.reason == known_typed.reason
    assert unknown_typed.verdict == "refuse"

    # NO ToolResult for either — the canon never ran, the sentinel never
    # left the store
    refute Enum.any?(Agent.get(store, & &1), fn {_id, {claims, _sig}} ->
             match?(%{type: "ToolResult"}, Schema.resolve(claims))
           end)

    assert inspect(known_refusal) =~ "GateDecision"
    refute inspect(known_refusal) =~ "classified sentinel"
    refute inspect(unknown_refusal) =~ "classified sentinel"
  end

  # B8 — memory.read wrong-typed entity (D10): the policy ABSTAINS, the run
  # clause answers "malformed action arguments: " <> args / "error". NEVER
  # unknown_entity (reserved for a well-formed string id with canon nil),
  # NEVER refuse (a refusal would re-open the existence-oracle question).
  test "B8: wrong-typed entity — malformed action arguments, never unknown_entity, never refuse" do
    store = start_store()
    {:ok, {epoch_claims, epoch_sig}} = Events.memory_policy(@agent_seed, @ts, ["e1"])
    epoch_id = Rhizomatic.Delta.id_hex(epoch_claims)
    Agent.update(store, &Map.put(&1, epoch_id, {epoch_claims, epoch_sig}))

    args = JSON.encode!(%{"entity" => 123})
    [gate_wire, result_wire] = run_memory_action(store, "memory.read", args)

    {:ok, gate_delta} = Store.verify(gate_wire)
    assert Schema.resolve(gate_delta.claims).verdict == "allow"

    {:ok, result_delta} = Store.verify(result_wire)
    result = Schema.resolve(result_delta.claims)
    assert result.type == "ToolResult"
    assert result.status == "error"
    assert result.result == "malformed action arguments: " <> args
    refute result.result =~ "unknown_entity"
    refute result.status == "refused"
  end

  # B8 ""-sub-cell — UNCONDITIONAL refuse: governed epoch x entity "" is
  # refused with the pinned entity reason ("" can never be allow-listed —
  # Delta.validate rejects an empty entity id, so B6's {"",
  # "unknown_entity"} is unreachable for ""; the "unless "" is allow-listed"
  # disjunct is UNCONSTRUCTABLE — a leg for it fails at fixture
  # construction, folded as moot)
  test "B8: entity \"\" — unconditional refuse, never a resolution" do
    store = start_store()
    {:ok, {epoch_claims, epoch_sig}} = Events.memory_policy(@agent_seed, @ts, ["e1"])
    epoch_id = Rhizomatic.Delta.id_hex(epoch_claims)
    Agent.update(store, &Map.put(&1, epoch_id, {epoch_claims, epoch_sig}))

    [refusal_wire] = run_memory_action(store, "memory.read", JSON.encode!(%{"entity" => ""}))

    {:ok, refusal_delta} = Store.verify(refusal_wire)
    refusal = Schema.resolve(refusal_delta.claims)
    assert refusal.verdict == "refuse"
    assert refusal.policy == "memory_policy"
    assert refusal.reason == "memory_policy: entity not allowed by the current epoch"
    assert refusal.policy_epoch == {:delta, epoch_id, "under"}

    # the allow-list disjunct is unconstructable: an epoch allow-listing ""
    # fails Delta.validate at fixture construction
    assert {:error, {:empty_string, :entity_id}} =
             Events.memory_policy(@agent_seed, @ts, [""])
  end
end
