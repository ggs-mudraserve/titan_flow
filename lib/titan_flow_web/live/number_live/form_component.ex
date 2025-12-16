defmodule TitanFlowWeb.NumberLive.FormComponent do
  use TitanFlowWeb, :live_component

  alias TitanFlow.WhatsApp
  alias TitanFlow.WhatsApp.PhoneNumber

  @impl true
  def render(assigns) do
    ~H"""
    <div class="p-6 space-y-6">
      <.form for={@form} id="phone-number-form" phx-target={@myself} phx-change="validate" phx-submit="save">
        <div class="space-y-4">
          <!-- Required IDs Section -->
          <div class="grid grid-cols-2 gap-4">
            <div>
              <label class="block text-sm font-medium text-gray-300 mb-2">Phone Number ID *</label>
              <input
                type="text"
                name={@form[:phone_number_id].name}
                value={@form[:phone_number_id].value}
                placeholder="e.g., 123456789012345"
                class="w-full bg-gray-700 border border-gray-600 rounded-lg px-4 py-2.5 text-white placeholder-gray-400 focus:outline-none focus:border-indigo-500"
              />
              <%= if @form[:phone_number_id].errors != [] do %>
                <p class="mt-1 text-red-400 text-sm">
                  <%= Enum.map(@form[:phone_number_id].errors, fn {msg, _} -> msg end) |> Enum.join(", ") %>
                </p>
              <% end %>
            </div>

            <div>
              <label class="block text-sm font-medium text-gray-300 mb-2">WABA ID *</label>
              <input
                type="text"
                name={@form[:waba_id].name}
                value={@form[:waba_id].value}
                placeholder="e.g., 123456789012345"
                class="w-full bg-gray-700 border border-gray-600 rounded-lg px-4 py-2.5 text-white placeholder-gray-400 focus:outline-none focus:border-indigo-500"
              />
              <%= if @form[:waba_id].errors != [] do %>
                <p class="mt-1 text-red-400 text-sm">
                  <%= Enum.map(@form[:waba_id].errors, fn {msg, _} -> msg end) |> Enum.join(", ") %>
                </p>
              <% end %>
            </div>
          </div>

          <!-- Phone Details -->
          <div class="grid grid-cols-2 gap-4">
            <div>
              <label class="block text-sm font-medium text-gray-300 mb-2">Mobile Number</label>
              <input
                type="text"
                name={@form[:mobile_number].name}
                value={@form[:mobile_number].value}
                placeholder="e.g., +91 98765 43210"
                class="w-full bg-gray-700 border border-gray-600 rounded-lg px-4 py-2.5 text-white placeholder-gray-400 focus:outline-none focus:border-indigo-500"
              />
              <p class="mt-1 text-xs text-gray-500">The actual phone number displayed to users</p>
            </div>

            <div>
              <label class="block text-sm font-medium text-gray-300 mb-2">Display Name</label>
              <input
                type="text"
                name={@form[:display_name].name}
                value={@form[:display_name].value}
                placeholder="e.g., Support Line"
                class="w-full bg-gray-700 border border-gray-600 rounded-lg px-4 py-2.5 text-white placeholder-gray-400 focus:outline-none focus:border-indigo-500"
              />
            </div>
          </div>

          <!-- Facebook App Credentials -->
          <div class="pt-4 border-t border-gray-700">
            <p class="text-sm text-gray-400 mb-4">📱 Facebook App Credentials</p>
            <div class="grid grid-cols-2 gap-4">
              <div>
                <label class="block text-sm font-medium text-gray-300 mb-2">App ID</label>
                <input
                  type="text"
                  name={@form[:app_id].name}
                  value={@form[:app_id].value}
                  placeholder="e.g., 123456789012345"
                  class="w-full bg-gray-700 border border-gray-600 rounded-lg px-4 py-2.5 text-white placeholder-gray-400 focus:outline-none focus:border-indigo-500"
                />
                <p class="mt-1 text-xs text-gray-500">From Meta Developer Portal</p>
              </div>

              <div>
                <label class="block text-sm font-medium text-gray-300 mb-2">App Secret</label>
                <input
                  type="password"
                  name={@form[:app_secret].name}
                  value={@form[:app_secret].value}
                  placeholder="Your app secret"
                  class="w-full bg-gray-700 border border-gray-600 rounded-lg px-4 py-2.5 text-white placeholder-gray-400 focus:outline-none focus:border-indigo-500"
                />
              </div>
            </div>
          </div>

          <!-- Access Token -->
      <div class="mb-4">
        <label class="block text-sm font-medium text-gray-300 mb-2">Access Token</label>
        <input
          type="password"
          name={@form[:access_token].name}
          value={@form[:access_token].value}
          placeholder="Your Meta API access token"
          class="w-full bg-gray-700 border border-gray-600 rounded-lg px-4 py-2.5 text-white placeholder-gray-400 focus:outline-none focus:border-indigo-500"
        />
        <p class="mt-1 text-xs text-gray-500">Permanent access token from Meta Business Suite</p>
      </div>



          <!-- AI System Prompt -->
          <div class="pt-4 border-t border-gray-700">
            <label class="block text-sm font-medium text-gray-300 mb-2">
              🤖 AI System Prompt
            </label>
            <textarea
              name={@form[:system_prompt].name}
              rows="4"
              placeholder="You are a helpful assistant. Keep answers short."
              class="w-full bg-gray-700 border border-gray-600 rounded-lg px-4 py-2.5 text-white placeholder-gray-400 focus:outline-none focus:border-indigo-500 resize-none"
            ><%= @form[:system_prompt].value %></textarea>
            <p class="mt-1 text-xs text-gray-500">This prompt defines the AI personality for this phone number.</p>
          </div>
        </div>

        <div class="flex items-center justify-end gap-3 pt-6">
          <.link
            patch={@patch}
            class="px-4 py-2.5 bg-gray-700 text-gray-300 rounded-lg font-medium text-sm hover:bg-gray-600 transition-colors"
          >
            Cancel
          </.link>
          <button
            type="submit"
            class="px-4 py-2.5 bg-indigo-600 text-white rounded-lg font-medium text-sm hover:bg-indigo-700 transition-colors"
          >
            <%= @submit_label %>
          </button>
        </div>
      </.form>
    </div>
    """
  end

  @impl true
  def update(%{phone_number: phone_number} = assigns, socket) do
    changeset = WhatsApp.change_phone_number(phone_number)

    {:ok, socket
      |> assign(assigns)
      |> assign_form(changeset)}
  end

  @impl true
  def handle_event("validate", %{"phone_number" => phone_number_params}, socket) do
    changeset =
      socket.assigns.phone_number
      |> WhatsApp.change_phone_number(phone_number_params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  @impl true
  def handle_event("save", %{"phone_number" => phone_number_params}, socket) do
    save_phone_number(socket, socket.assigns.action, phone_number_params)
  end

  defp save_phone_number(socket, :edit, phone_number_params) do
    case WhatsApp.update_phone_number(socket.assigns.phone_number, phone_number_params) do
      {:ok, phone_number} ->
        notify_parent({:saved, phone_number})
        {:noreply, socket
          |> put_flash(:info, "Phone number updated!")
          |> push_patch(to: socket.assigns.patch)}
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp save_phone_number(socket, :new, phone_number_params) do
    case WhatsApp.create_phone_number(phone_number_params) do
      {:ok, phone_number} ->
        notify_parent({:saved, phone_number})
        {:noreply, socket
          |> put_flash(:info, "Phone number added!")
          |> push_patch(to: socket.assigns.patch)}
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset, as: :phone_number))
  end

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})
end
