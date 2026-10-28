defmodule WeworkaiWeb.Router do
  use WeworkaiWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {WeworkaiWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", WeworkaiWeb do
    pipe_through :browser

    get "/attachments/:id", AttachmentController, :show

    live_session :default, on_mount: WeworkaiWeb.NotificationsHook do
      live "/", BoardLive, :index
      live "/dashboard", DashboardLive, :index
      live "/dashboard/new", DashboardLive, :new
      live "/dashboard/runs/:id", RunLive, :show
      live "/tasks/new", BoardLive, :new
      live "/tasks/:id", TaskLive, :show
      live "/tasks/:id/edit", BoardLive, :edit
      live "/audit", AuditLive, :index
      live "/audit/:id", AuditLive, :show
      live "/employees", EmployeesLive, :index
      live "/employees/new", EmployeesLive, :new
      live "/employees/:id/edit", EmployeesLive, :edit
      live "/employees/:id/agent", EmployeesLive, :agent
      live "/connectors", ConnectorsLive, :index
      live "/connectors/new", ConnectorsLive, :new
      live "/connectors/:id/edit", ConnectorsLive, :edit
      live "/notifications", NotificationsLive, :index
      live "/workflows", WorkflowsLive, :index
      live "/workflows/new", WorkflowsLive, :new
      live "/workflows/from-template", WorkflowsLive, :template
      live "/workflows/:id", WorkflowLive, :show
      live "/workflows/:id/edit", WorkflowsLive, :edit
      live "/recurring", RecurringLive, :index
      live "/recurring/new", RecurringLive, :new
      live "/recurring/:id/edit", RecurringLive, :edit
    end
  end

  # Only the e2e instance answers it (Weworkai.E2E.enabled?/0).
  scope "/e2e", WeworkaiWeb do
    pipe_through :api

    post "/reset", E2EController, :reset
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:weworkai, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: WeworkaiWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
