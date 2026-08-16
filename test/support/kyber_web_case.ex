defmodule KyberWeb.Case do
  @moduledoc """
  Shared harness for the T19 dashboard LiveView tests: boots the dashboard
  tree (collector + endpoint) once per test, exposes the Phoenix.ConnTest /
  Phoenix.LiveViewTest imports with the dashboard endpoint, and the
  sleep-free state-polling helper (`receive ... after` — never
  `Process.sleep`).
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest

      @endpoint KyberWeb.Endpoint

      setup do
        {:ok, sup} = KyberWeb.Application.start(:normal, [])

        on_exit(fn ->
          # the tree may already be unwinding (an earlier on_exit or a test
          # crash) — the stop is defensive, never fatal
          try do
            if Process.alive?(sup), do: Supervisor.stop(sup)
          catch
            _, _ -> :ok
          end
        end)

        :ok
      end

      # explicit state polling (the no-Process.sleep rule): bounded
      # receive-timeout loop until `fun.()` is truthy
      defp poll_until(fun, timeout \\ 2_000) do
        if fun.() do
          :ok
        else
          if timeout <= 0, do: raise("poll_until timed out")

          receive do
          after
            10 -> poll_until(fun, timeout - 10)
          end
        end
      end
    end
  end
end
