defmodule Aviary.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      AviaryWeb.Telemetry,
      Aviary.Repo,
      {DNSCluster, query: Application.get_env(:aviary, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Aviary.PubSub},
      # Start a worker by calling: Aviary.Worker.start_link(arg)
      # {Aviary.Worker, arg},
      # Start to serve requests, typically the last entry
      AviaryWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Aviary.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AviaryWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
