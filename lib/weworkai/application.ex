defmodule Weworkai.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        WeworkaiWeb.Telemetry,
        Weworkai.Repo,
        {DNSCluster, query: Application.get_env(:weworkai, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Weworkai.PubSub},
        {Registry, keys: :duplicate, name: Weworkai.Agents.SessionWatchers},
        Weworkai.Agents.SessionPoller
      ] ++ scheduler() ++ [WeworkaiWeb.Endpoint]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Weworkai.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tests drive the scheduler's functions directly; a ticking process would race the SQL sandbox.
  defp scheduler do
    if Application.get_env(:weworkai, :start_scheduler, true),
      do: [Weworkai.Scheduling.Scheduler],
      else: []
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    WeworkaiWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
