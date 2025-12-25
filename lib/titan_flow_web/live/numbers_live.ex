defmodule TitanFlowWeb.NumbersLive do
  use TitanFlowWeb, :live_view

  alias TitanFlow.WhatsApp
  alias TitanFlowWeb.DateTimeHelpers

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(current_path: "/numbers")
      |> assign(page_title: "WhatsApp Numbers")
      |> assign(syncing_id: nil)
      |> load_numbers()

    {:ok, socket}
  end

  @impl true
  def handle_event("sync_number", %{"id" => id}, socket) do
    number = WhatsApp.get_phone_number!(id)

    # In a real app we might want to do this async, but for now we'll do it inline or via Task if needed
    # mocking async for UI feel
    send(self(), {:run_sync, number})

    {:noreply, assign(socket, syncing_id: id)}
  end

  @impl true
  def handle_info({:run_sync, number}, socket) do
    case WhatsApp.sync_phone_number(number) do
      {:ok, _updated_number} ->
        socket
        |> put_flash(:info, "Number synced successfully")
        |> assign(syncing_id: nil)
        |> load_numbers()
        |> noreply()

      {:error, _} ->
        socket
        |> put_flash(:error, "Failed to sync number")
        |> assign(syncing_id: nil)
        |> noreply()
    end
  end

  defp load_numbers(socket) do
    assign(socket, phone_numbers: WhatsApp.list_phone_numbers())
  end

  defp noreply(socket), do: {:noreply, socket}

  defp quality_color(rating) do
    case rating do
      "GREEN" -> "text-emerald-400 bg-emerald-500/20 border-emerald-500/30"
      "YELLOW" -> "text-amber-400 bg-amber-500/20 border-amber-500/30"
      "RED" -> "text-red-400 bg-red-500/20 border-red-500/30"
      _ -> "text-zinc-400 bg-zinc-700/50 border-zinc-700"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <.page_header title="WhatsApp Numbers">
        <:actions>
          <.button variant={:primary} size={:sm}>+ Add Number</.button>
        </:actions>
      </.page_header>

      <%= if Enum.empty?(@phone_numbers) do %>
        <div class="bg-zinc-900 rounded-lg border border-zinc-800 p-12 text-center">
          <span class="text-4xl text-zinc-700">📱</span>
          <p class="mt-4 text-zinc-400">No phone numbers connected.</p>
          <p class="mt-2 text-zinc-500 text-sm">
            Add a WhatsApp Business API number to get started.
          </p>
        </div>
      <% else %>
        <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
          <%= for number <- @phone_numbers do %>
            <div class="bg-zinc-900 rounded-lg border border-zinc-800 hover:border-zinc-700 transition-colors p-5">
              <div class="flex items-start justify-between mb-5">
                <div class="flex items-center gap-4">
                  <div class="w-10 h-10 rounded-lg bg-emerald-500/20 flex items-center justify-center text-xl text-emerald-400">
                    📞
                  </div>
                  <div>
                    <h3 class="font-medium text-zinc-100"><%= number.display_name || "Unknown Name" %></h3>
                    <p class="text-indigo-400 font-mono text-sm mt-0.5"><%= number.phone_number_id %></p>
                    <div class="flex items-center gap-2 mt-2">
                      <span class="text-xs text-zinc-500 uppercase tracking-wider font-medium">Quality:</span>
                      <span class={"text-xs font-medium px-2 py-0.5 rounded border #{quality_color(number.quality_rating)}"}>
                        <%= number.quality_rating || "UNKNOWN" %>
                      </span>
                    </div>
                  </div>
                </div>
                <div class="px-2 py-0.5 rounded text-xs font-medium bg-emerald-500/20 text-emerald-400 border border-emerald-500/30">
                  Active
                </div>
              </div>

              <div class="bg-zinc-800/50 rounded-lg p-3 mb-5 border border-zinc-800">
                <div class="flex items-center justify-between text-sm">
                  <span class="text-zinc-500 font-medium">Last Synced</span>
                  <span class="text-zinc-300 font-mono text-xs">
                    <%= if number.updated_at, do: DateTimeHelpers.format_12_hour(number.updated_at), else: "Never" %>
                  </span>
                </div>
              </div>

              <div class="flex items-center gap-2 pt-4 border-t border-zinc-800">
                <button
                  phx-click="sync_number"
                  phx-value-id={number.id}
                  disabled={@syncing_id == number.id}
                  class="flex-1 flex items-center justify-center gap-2 h-8 px-3 bg-indigo-600 hover:bg-indigo-500 text-white rounded text-sm font-medium transition-colors disabled:opacity-50"
                >
                  <%= if @syncing_id == "#{number.id}" do %>
                    <span class="animate-spin">⟳</span> Syncing...
                  <% else %>
                    🔄 Sync
                  <% end %>
                </button>
                <button class="h-8 px-3 border border-zinc-700 text-zinc-300 rounded text-sm font-medium hover:bg-zinc-800 transition-colors">
                  Details
                </button>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end
end
