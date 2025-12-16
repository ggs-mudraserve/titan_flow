defmodule TitanFlow.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Get Redis config
    redix_config = Application.get_env(:titan_flow, :redix)

    children = [
      TitanFlowWeb.Telemetry,
      TitanFlow.Repo,
      {DNSCluster, query: Application.get_env(:titan_flow, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: TitanFlow.PubSub},

      # Redis connection pool
      {Redix,
       host: redix_config[:host],
       port: redix_config[:port],
       password: redix_config[:password],
       name: :redix},

      # Hammer rate limiter backend
      {Hammer.Backend.Redis, [
        expiry_ms: 60_000 * 60 * 2,  # 2 hours
        redix_config: [
          host: redix_config[:host],
          port: redix_config[:port],
          password: redix_config[:password]
        ]
      ]},

      # Registry for WhatsApp rate limiters (one per phone_number_id)
      {Registry, keys: :unique, name: TitanFlow.WhatsApp.RateLimiterRegistry},

      # Registry for Broadway campaign pipelines (one per phone_number_id)
      {Registry, keys: :unique, name: TitanFlow.Campaigns.PipelineRegistry},

      # Registry for JIT BufferManagers (one per campaign+phone combination)
      {Registry, keys: :unique, name: TitanFlow.BufferRegistry},

      # DynamicSupervisor for BufferManagers
      {DynamicSupervisor, strategy: :one_for_one, name: TitanFlow.BufferSupervisor},

      # DynamicSupervisor for Phone Number Rate Limiters
      {DynamicSupervisor, strategy: :one_for_one, name: TitanFlow.PhoneSupervisor},

      # Draft campaign cleanup (deletes orphan drafts after 1 hour) -- REMOVED
      # TitanFlow.Campaigns.DraftCleanup,

      # Periodic Redis-to-Postgres counter sync (every 5 minutes for running campaigns)
      TitanFlow.Campaigns.CounterSync,

      # ETS cache for phone_number_id -> db_id lookups (webhook optimization)
      TitanFlow.WhatsApp.PhoneCache,

      # Campaign pipelines are started dynamically when a campaign begins:
      # TitanFlow.Campaigns.Pipeline.start_link(phone_number_id: "...", template_name: "...", ...)

      # Start to serve requests, typically the last entry
      TitanFlowWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: TitanFlow.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    TitanFlowWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
