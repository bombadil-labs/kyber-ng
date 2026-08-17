defmodule KyberWeb.Application do
  @moduledoc """
  The T19 dashboard supervision tree (M4): the span collector + the Phoenix
  endpoint, started on the dashboard path ONLY — `mix kyber.dashboard` and
  the dashboard tests. The substrate `:kyber` application is untouched: the
  store/daemon ride their existing tree (`Kyber.Supervisor`), and the
  escript never loads Phoenix (`:kyber`'s extra_applications is unchanged —
  Phoenix apps are ensured here, at the dashboard boundary).
  """
  use Application

  @impl true
  def start(_type, _args), do: start_link([])

  @doc """
  Start the dashboard tree. Ensures the Phoenix runtime apps first (they are
  NOT in :kyber's extra_applications — the escript must keep booting without
  them), then supervises collector + endpoint (`one_for_one`). Callable from
  `mix kyber.dashboard`, the dashboard tests (`start_supervised!`-style via
  `start_link/1`), or a separate BEAM.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(_opts \\ []) do
    {:ok, _} = Application.ensure_all_started(:phoenix)
    {:ok, _} = Application.ensure_all_started(:phoenix_html)
    {:ok, _} = Application.ensure_all_started(:phoenix_live_view)
    {:ok, _} = Application.ensure_all_started(:plug_cowboy)

    Supervisor.start_link(
      [
        # the span ring buffer + ETS trace index (registered node-wide; a
        # crash loses only ephemeral traces — I7)
        Kyber.Trace.Collector,
        # the LiveView endpoint (server: true in dev — `mix kyber.dashboard`)
        KyberWeb.Endpoint
      ],
      strategy: :one_for_one,
      name: KyberWeb.Supervisor
    )
  end
end
