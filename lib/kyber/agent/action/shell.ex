defmodule Kyber.Agent.Action.Shell do
  @moduledoc """
  The one bounded shell action (T12): `sh.run` executes a command through
  `/bin/sh -c` with the cwd SANDBOXED to the workspace root, a SCRUBBED
  environment (every BEAM process variable — API keys included — is
  explicitly unset; the child gets PATH/HOME/TMPDIR only: the key-refusal
  doctrine extends to subprocesses), a HARD timeout (the port is closed,
  killing the spawned process), and a CAPPED output (the kept prefix plus a
  truncation marker — never a silent truncation).

  A non-zero exit is a `ToolResult` status (`"exit:<code>"`), a timeout is
  `"timeout"` — never a crash. `sh.run` is idempotent only for pure
  commands; the gate should hold side-effecting commands at `prompt` /
  `deny` (the executor's answer-from-the-store rule covers crash-window
  re-fires after the `ToolResult` persists).

  The containment contract is EXACTLY four bounds (T14d D8): (1) the cwd
  is sandboxed to the workspace root; (2) the environment is scrubbed to
  exactly PATH/HOME/TMPDIR; (3) a 5_000 ms hard tree-kill; (4) a capped
  output with a truncation marker. fs-escape RUNS as the DECLARED HOLE —
  lexical command screening is a placebo and is never the boundary;
  GOVERNANCE (the permission gate) is the control.
  """

  alias Kyber.Agent.Action

  @doc "Run a command. Args: `command`. Context: `:workspace`, `:shell_timeout` (ms), `:output_cap` (bytes)."
  @spec run(map(), map()) :: {String.t(), String.t()}
  def run(%{"command" => command}, %{workspace: root} = context) when is_binary(command) do
    timeout = Map.get(context, :shell_timeout, 5_000)
    cap = Map.get(context, :output_cap, 65_536)
    cwd = Path.expand(root)

    port =
      Port.open({:spawn_executable, ~c"/bin/sh"}, [
        :binary,
        :stream,
        :exit_status,
        :stderr_to_stdout,
        # the port child is ALREADY a process-group leader (verified: its
        # pgid == its own pid), so the hard timeout can kill the WHOLE group
        # (sh + its children) with `kill -KILL -<os_pid>`: on this box sh -c
        # does NOT exec a simple command, so killing the sh alone orphans
        # the child (a `sleep 30` keeps running after the timeout)
        args: ["-c", command],
        cd: String.to_charlist(cwd),
        env: scrubbed_env(cwd)
      ])

    collect(port, cap, "", false, System.monotonic_time(:millisecond) + timeout, timeout, cwd)
  end

  def run(_args, _context), do: {"sh.run: a \"command\" string argument is required", "error"}

  @doc "The marker appended when a run is killed by the hard timeout — never silent."
  @spec timeout_marker(non_neg_integer()) :: String.t()
  def timeout_marker(timeout),
    do: "[killed: hard timeout of " <> Integer.to_string(timeout) <> " ms exceeded]"

  # -------------------------------------------------------------- machinery

  defp collect(port, cap, acc, truncated?, deadline, timeout, root) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, chunk}} ->
        {acc, truncated?} = accumulate(acc, chunk, cap, truncated?)
        collect(port, cap, acc, truncated?, deadline, timeout, root)

      {^port, {:exit_status, code}} ->
        {acc, truncated?} = drain(port, cap, acc, truncated?)
        {finish(acc, truncated?, cap), status_for(code)}
    after
      remaining ->
        kill(port, root)
        {acc, truncated?} = drain(port, cap, acc, truncated?)
        {finish(acc, truncated?, cap) <> "\n" <> timeout_marker(timeout), "timeout"}
    end
  end

  # the hard timeout kills the whole process TREE, not just the port (fold
  # from the T12 verdict, A's best attribute): a silent child (`sleep 30`)
  # survives a bare Port.close. Passes: (1) walk /proc for descendants and
  # SIGKILL each; (2) kill the sh (no forks can follow); (3) sweep stragglers
  # by CWD — a child forked in the race window is reparented to init and
  # keeps the workspace as its cwd, so scope the sweep to processes whose
  # cwd resolves inside the workspace root. A cmdline-pattern sweep is
  # banned: it can match the very shells running the tests (observed).
  defp kill(port, root) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        os_pid
        |> descendants()
        |> Enum.each(&System.cmd("kill", ["-KILL", Integer.to_string(&1)]))

        System.cmd("kill", ["-KILL", Integer.to_string(os_pid)])
        sweep_by_cwd(root)

      _closed ->
        :ok
    end

    Port.close(port)
  catch
    # the port can die between info and close; the process is gone either way
    :error, :badarg -> :ok
  end

  # kill every process whose cwd resolves inside the workspace root — the
  # deterministic straggler sweep (reparented orphans keep their cwd)
  defp sweep_by_cwd(root) do
    root_real = Path.expand(root)

    for dir <- File.ls!("/proc"),
        dir =~ ~r/^\d+$/,
        {:ok, cwd} <- [File.read_link("/proc/" <> dir <> "/cwd")],
        String.starts_with?(cwd, root_real) do
      System.cmd("kill", ["-KILL", dir])
    end

    :ok
  end

  # all descendants of `root` (depth-first, /proc stat ppid walk — no
  # Process.group_leader/port state, works on WSL)
  defp descendants(root) do
    root
    |> children()
    |> Enum.flat_map(&[&1 | descendants(&1)])
  end

  defp children(pid) do
    for dir <- File.ls!("/proc"),
        dir =~ ~r/^\d+$/,
        {ppid, this} <- [stat_ppid("/proc/" <> dir)],
        ppid == pid,
        do: this
  end

  # read `ppid` out of /proc/<pid>/stat — the comm field can contain spaces
  # and parens, so parse after the LAST `)` of the comm
  defp stat_ppid(path) do
    with {:ok, data} <- File.read(path),
         {idx, 2} <- :binary.match(data, ") ") do
      after_comm = binary_part(data, idx + 2, byte_size(data) - idx - 2)
      [_state, ppid | _] = String.split(after_comm, " ")

      {String.to_integer(ppid),
       String.to_integer(String.trim_trailing(path, "/") |> String.split("/") |> List.last())}
    else
      _ -> :skip
    end
  end

  # a closed/exited port may still have queued data — poll it dry (never a sleep)
  defp drain(port, cap, acc, truncated?) do
    receive do
      {^port, {:data, chunk}} ->
        {acc, truncated?} = accumulate(acc, chunk, cap, truncated?)
        drain(port, cap, acc, truncated?)
    after
      0 -> {acc, truncated?}
    end
  end

  defp accumulate(acc, chunk, cap, truncated?) do
    if byte_size(acc) >= cap do
      {acc, true}
    else
      kept = acc <> chunk

      if byte_size(kept) > cap,
        do: {binary_part(kept, 0, cap), true},
        else: {kept, truncated?}
    end
  end

  defp finish(acc, true, cap), do: acc <> "\n" <> Action.truncation_marker(cap)
  defp finish(acc, false, _cap), do: acc

  defp status_for(0), do: "ok"
  defp status_for(code), do: "exit:" <> Integer.to_string(code)

  # the key-refusal doctrine for subprocesses: every inherited variable is
  # explicitly unset, then a minimal environment is granted
  defp scrubbed_env(cwd) do
    keep = ["PATH", "HOME", "TMPDIR"]

    deleted =
      for {name, _} <- System.get_env(), name not in keep do
        {String.to_charlist(name), false}
      end

    deleted ++
      [
        {~c"PATH", ~c"/usr/local/bin:/usr/bin:/bin"},
        {~c"HOME", String.to_charlist(cwd)},
        {~c"TMPDIR", ~c"/tmp"}
      ]
  end
end
