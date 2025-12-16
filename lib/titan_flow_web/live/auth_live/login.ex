defmodule TitanFlowWeb.AuthLive.Login do
  use TitanFlowWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, error: nil, current_path: "/login"),
     layout: {TitanFlowWeb.Layouts, :root}}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen flex items-center justify-center bg-base-200">
      <div class="w-full max-w-sm">
        <div class="bg-base-100 rounded-xl border border-base-200 shadow-lg p-8">
          <div class="text-center mb-8">
            <h1 class="text-2xl font-bold text-primary">⚡ TitanFlow</h1>
            <p class="text-sm text-base-content/60 mt-2">Enter your PIN to continue</p>
          </div>

          <form phx-submit="unlock" class="space-y-6">
            <div>
              <label class="block text-sm font-medium text-base-content mb-2">
                Enter Admin PIN
              </label>
              <input
                type="password"
                name="pin"
                placeholder="••••••"
                autocomplete="current-password"
                autofocus
                class="w-full bg-base-200 border border-base-300 rounded-lg px-4 py-3 text-base-content text-center text-lg tracking-widest focus:ring-2 focus:ring-primary focus:border-primary"
              />
            </div>

            <%= if @error do %>
              <div class="bg-error/10 border border-error/20 text-error text-sm rounded-lg px-4 py-3 text-center">
                <%= @error %>
              </div>
            <% end %>

            <button
              type="submit"
              class="w-full px-4 py-3 bg-primary hover:bg-primary-focus text-primary-content rounded-lg font-medium transition-colors"
            >
              Unlock Dashboard
            </button>
          </form>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("unlock", %{"pin" => pin}, socket) do
    expected_pin = Application.get_env(:titan_flow, :admin_pin, "123456")

    if pin == expected_pin do
      {:noreply,
       socket
       |> put_flash(:info, "Welcome back!")
       |> redirect(to: ~p"/?authenticated=true")}
    else
      {:noreply, assign(socket, error: "Incorrect PIN")}
    end
  end
end
