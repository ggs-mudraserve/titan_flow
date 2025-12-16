defmodule TitanFlowWeb.NumberLive.Index do
  use TitanFlowWeb, :live_view

  alias TitanFlow.WhatsApp
  alias TitanFlow.WhatsApp.PhoneNumber

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(current_path: "/numbers")
      |> assign(page_title: "WhatsApp Numbers")
      |> assign(syncing: nil)
      |> load_phone_numbers()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    phone_number = WhatsApp.get_phone_number!(id)
    socket
    |> assign(:page_title, "Edit Phone Number")
    |> assign(:phone_number, phone_number)
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "Add Phone Number")
    |> assign(:phone_number, %PhoneNumber{})
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "WhatsApp Numbers")
    |> assign(:phone_number, nil)
  end

  @impl true
  def handle_info({TitanFlowWeb.NumberLive.FormComponent, {:saved, _phone_number}}, socket) do
    {:noreply, load_phone_numbers(socket)}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    phone_number = WhatsApp.get_phone_number!(id)
    {:ok, _} = WhatsApp.delete_phone_number(phone_number)
    
    {:noreply, socket
      |> put_flash(:info, "Phone number deleted!")
      |> load_phone_numbers()}
  end

  @impl true
  def handle_event("sync", %{"id" => id}, socket) do
    phone_number = WhatsApp.get_phone_number!(id)
    socket = assign(socket, syncing: String.to_integer(id))
    
    Task.start(fn ->
      result = WhatsApp.sync_phone_number(phone_number)
      send(self(), {:sync_complete, id, result})
    end)
    
    {:noreply, socket}
  end

  @impl true
  def handle_info({:sync_complete, _id, result}, socket) do
    socket = assign(socket, syncing: nil)
    
    socket = case result do
      {:ok, _} -> 
        socket
        |> put_flash(:info, "Phone number synced successfully!")
        |> load_phone_numbers()
      {:error, reason} ->
        put_flash(socket, :error, "Sync failed: #{inspect(reason)}")
    end
    
    {:noreply, socket}
  end

  defp load_phone_numbers(socket) do
    assign(socket, phone_numbers: WhatsApp.list_phone_numbers())
  end

  defp quality_badge_class(rating) do
    case rating do
      "GREEN" -> "bg-green-500/20 text-green-400 border-green-500/30"
      "YELLOW" -> "bg-yellow-500/20 text-yellow-400 border-yellow-500/30"
      "RED" -> "bg-red-500/20 text-red-400 border-red-500/30"
      _ -> "bg-gray-500/20 text-gray-400 border-gray-500/30"
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <!-- Header -->
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-2xl font-bold text-white">WhatsApp Numbers</h1>
          <p class="text-gray-400 text-sm mt-1">Manage your connected phone numbers</p>
        </div>
        <.link
          patch={~p"/numbers/new"}
          class="px-4 py-2 bg-indigo-600 text-white rounded-lg font-medium text-sm hover:bg-indigo-700 transition-colors"
        >
          + Add Number
        </.link>
      </div>

      <!-- Phone Numbers List -->
      <div class="bg-gray-800 rounded-xl border border-gray-700 overflow-hidden">
        <%= if Enum.empty?(@phone_numbers) do %>
          <div class="p-12 text-center">
            <span class="text-4xl">📱</span>
            <p class="mt-4 text-gray-400">No phone numbers configured yet.</p>
            <.link
              patch={~p"/numbers/new"}
              class="mt-4 text-indigo-400 hover:text-indigo-300 font-medium inline-block"
            >
              Add your first number →
            </.link>
          </div>
        <% else %>
          <table class="w-full">
            <thead class="bg-gray-700/50">
              <tr>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-400 uppercase tracking-wider">Phone Number</th>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-400 uppercase tracking-wider">WABA ID</th>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-400 uppercase tracking-wider">Quality</th>
                <th class="px-6 py-3 text-left text-xs font-medium text-gray-400 uppercase tracking-wider">Status</th>
                <th class="px-6 py-3 text-right text-xs font-medium text-gray-400 uppercase tracking-wider">Actions</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-700">
              <%= for phone <- @phone_numbers do %>
                <tr class="hover:bg-gray-700/30 transition-colors">
                  <td class="px-6 py-4">
                    <div class="flex items-center gap-3">
                      <span class="text-xl">📱</span>
                      <div>
                        <p class="text-white font-medium"><%= phone.display_name || phone.phone_number_id %></p>
                        <p class="text-gray-400 text-sm"><%= phone.phone_number_id %></p>
                      </div>
                    </div>
                  </td>
                  <td class="px-6 py-4 text-gray-300 text-sm"><%= phone.waba_id %></td>
                  <td class="px-6 py-4">
                    <span class={"px-2.5 py-1 rounded-full text-xs font-medium border #{quality_badge_class(phone.quality_rating)}"}>
                      <%= phone.quality_rating %>
                    </span>
                  </td>
                  <td class="px-6 py-4">
                    <%= if phone.is_warmup_active do %>
                      <span class="text-yellow-400 text-sm">🔥 Warming up</span>
                    <% else %>
                      <span class="text-green-400 text-sm">✓ Active</span>
                    <% end %>
                  </td>
                  <td class="px-6 py-4">
                    <div class="flex items-center justify-end gap-2">
                      <button
                        phx-click="sync"
                        phx-value-id={phone.id}
                        class="px-3 py-1.5 bg-gray-700 text-gray-300 rounded-lg text-sm hover:bg-gray-600 transition-colors disabled:opacity-50"
                        disabled={@syncing == phone.id}
                      >
                        <%= if @syncing == phone.id do %>
                          <span class="animate-spin">⟳</span> Syncing...
                        <% else %>
                          🔄 Sync
                        <% end %>
                      </button>
                      <.link
                        patch={~p"/numbers/#{phone}/edit"}
                        class="px-3 py-1.5 bg-gray-700 text-gray-300 rounded-lg text-sm hover:bg-gray-600 transition-colors"
                      >
                        ✏️ Edit
                      </.link>
                      <button
                        phx-click="delete"
                        phx-value-id={phone.id}
                        data-confirm="Are you sure you want to delete this phone number?"
                        class="px-3 py-1.5 bg-red-600/20 text-red-400 rounded-lg text-sm hover:bg-red-600/30 transition-colors"
                      >
                        🗑️
                      </button>
                    </div>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        <% end %>
      </div>
    </div>

    <!-- Modal -->
    <%= if @live_action in [:new, :edit] do %>
      <div class="fixed inset-0 z-50 overflow-y-auto">
        <div class="flex min-h-full items-center justify-center p-4">
          <!-- Backdrop -->
          <.link patch={~p"/numbers"} class="fixed inset-0 bg-black/60"></.link>
          
          <!-- Modal Content -->
          <div class="relative bg-gray-800 rounded-2xl shadow-xl w-full max-w-lg border border-gray-700">
            <div class="p-6 border-b border-gray-700">
              <h2 class="text-xl font-bold text-white">
                <%= if @live_action == :edit, do: "Edit Phone Number", else: "Add Phone Number" %>
              </h2>
            </div>
            
            <.live_component
              module={TitanFlowWeb.NumberLive.FormComponent}
              id={@phone_number.id || :new}
              action={@live_action}
              phone_number={@phone_number}
              patch={~p"/numbers"}
              submit_label={if @live_action == :edit, do: "Update", else: "Add Number"}
            />
          </div>
        </div>
      </div>
    <% end %>
    """
  end
end
