defmodule TitanFlowWeb.Router do
  use TitanFlowWeb, :router

  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {TitanFlowWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :require_auth do
    plug TitanFlowWeb.Plugs.RequireAuth
  end

  # Public routes (no auth)
  scope "/", TitanFlowWeb do
    pipe_through :browser

    live "/login", AuthLive.Login
    post "/login", SessionController, :create
  end

  # Protected application routes
  scope "/", TitanFlowWeb do
    pipe_through [:browser, :require_auth]

    live "/", DashboardLive.Index
    live "/dashboard", DashboardLive.Index
    live "/campaigns", CampaignsLive
    live "/campaigns/new", CampaignLive.New
    live "/campaigns/:id/resume", CampaignLive.Resume
    live "/inbox", InboxLive.Index
    live "/numbers", NumberLive.Index, :index
    live "/numbers/new", NumberLive.Index, :new
    live "/numbers/:id/edit", NumberLive.Index, :edit
    live "/templates", TemplateLive.Index
    live "/settings", SettingsLive
  end

  scope "/api", TitanFlowWeb do
    pipe_through :api

    # Primary webhook routes (with /whatsapp suffix)
    get "/webhooks/whatsapp", WebhookController, :verify
    post "/webhooks/whatsapp", WebhookController, :handle

    # Alias routes (without /whatsapp suffix) - for Meta compatibility
    get "/webhooks", WebhookController, :verify
    post "/webhooks", WebhookController, :handle
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:titan_flow, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through [:fetch_session, :protect_from_forgery]

      live_dashboard "/dashboard", metrics: TitanFlowWeb.Telemetry
    end
  end
end
