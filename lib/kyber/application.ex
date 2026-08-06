defmodule Kyber.Application do
  @moduledoc """
  The kyber OTP application (T3): a `one_for_one` Supervisor with exactly one
  child, `Kyber.DurableStore` (restart: :permanent — a crash respawns it and
  replay rebuilds the set from disk). The log path comes from app env
  (`Application.get_env(:kyber, :log_path)`), defaulting to
  `~/.kyber/store.jsonl` under the user home.

  This module OWNS the side effect that the log's parent directory exists:
  `~/.kyber/` is mkdir_p'd BEFORE the child starts, so a fresh account's
  first append succeeds instead of silently returning
  `{:error, :persist_failed}`.

  `Kyber.Store` (the T1 in-memory Agent) is deliberately NOT started —
  `DurableStore` is THE running store.
  """

  use Application

  alias Kyber.DurableStore

  @impl true
  def start(_type, _args) do
    log_path = Application.get_env(:kyber, :log_path) || default_log_path()

    # the parent dir exists before the child starts (AC8) — only then can the
    # lazy-open first append land instead of failing with :persist_failed
    with :ok <- File.mkdir_p(Path.dirname(log_path)) do
      Supervisor.start_link(
        [
          %{
            id: DurableStore,
            start: {DurableStore, :start_link, [log_path]},
            restart: :permanent
          }
        ],
        strategy: :one_for_one,
        # named (T10) so `Kyber.Daemon.boot/1` can join the tree dynamically —
        # only a supervised daemon gets a graceful terminate (lock release) on
        # SIGTERM's init:stop
        name: Kyber.Supervisor
      )
    end
  end

  defp default_log_path do
    # P5 low finding 2: with HOME unset System.user_home() returns "" and
    # Path.join would yield a CWD-relative path — the real store silently
    # landing in the working directory. Refuse loudly (config.exs guards the
    # same case at config-load time).
    case System.user_home() do
      "" ->
        raise "kyber: cannot resolve the default log_path — HOME is unset " <>
                "(System.user_home() is empty). Set :kyber, :log_path to an " <>
                "absolute path explicitly."

      home ->
        Path.join(home, ".kyber/store.jsonl")
    end
  end
end
