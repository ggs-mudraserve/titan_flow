defmodule TitanFlowWeb.CampaignLive.Retry do
  @moduledoc """
  Retry failed contacts for a completed campaign using the same Sender Configuration UI as Resume.
  """

  use TitanFlowWeb, :live_view
  require Logger

  alias TitanFlow.Campaigns
  alias TitanFlow.Templates
  alias TitanFlow.WhatsApp

  @default_mps 80

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Campaigns.get_campaign(String.to_integer(id)) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Campaign not found")
         |> push_navigate(to: ~p"/campaigns")}

      campaign ->
        if campaign.status != "completed" do
          {:ok,
           socket
           |> put_flash(:error, "Campaign cannot be retried from its current state")
           |> push_navigate(to: ~p"/campaigns")}
        else
          # Touch updated_at to prevent cleanup while user is on page
          Campaigns.update_campaign(campaign, %{})

          # Get phones, refresh templates from Meta, then fetch fresh templates
          phone_numbers = WhatsApp.list_phone_numbers()

          Enum.each(phone_numbers, fn phone ->
            try do
              WhatsApp.sync_templates(phone.id)
            rescue
              _ -> :ok
            end
          end)

          templates = Templates.list_templates()

          senders_config = build_senders_config(campaign)

          socket =
            socket
            |> assign(current_path: "/campaigns")
            |> assign(page_title: "Retry Failed Contacts")
            |> assign(campaign: campaign)
            |> assign(all_templates: templates)
            |> assign(phone_numbers: phone_numbers)
            |> assign(senders_config: senders_config)
            |> assign(campaign_name: campaign.name)
            |> assign(saving: false)
            |> assign(error: nil)

          {:ok, socket}
        end
    end
  end

  defp build_senders_config(campaign) do
    cond do
      campaign.senders_config && campaign.senders_config != [] ->
        Enum.map(campaign.senders_config, fn config ->
          %{
            id: generate_id(),
            phone_id: config["phone_id"],
            template_ids: config["template_ids"] || [],
            mps: parse_mps(config["mps"], @default_mps)
          }
        end)

      campaign.phone_ids && campaign.phone_ids != [] ->
        Enum.map(campaign.phone_ids, fn phone_id ->
          %{
            id: generate_id(),
            phone_id: phone_id,
            template_ids: campaign.template_ids || [],
            mps: @default_mps
          }
        end)

      true ->
        [%{id: generate_id(), phone_id: nil, template_ids: [], mps: @default_mps}]
    end
  end

  @impl true
  def handle_event("validate", params, socket) do
    campaign_params = params["campaign"] || %{}
    campaign_name = campaign_params["name"] || socket.assigns.campaign_name

    socket =
      socket
      |> assign(campaign_name: campaign_name, error: nil)
      |> update_senders_from_params(params)

    {:noreply, socket}
  end

  @impl true
  def handle_event("add_sender", _params, socket) do
    new_sender = %{id: generate_id(), phone_id: nil, template_ids: [], mps: @default_mps}
    senders = socket.assigns.senders_config ++ [new_sender]
    {:noreply, assign(socket, senders_config: senders)}
  end

  @impl true
  def handle_event("remove_sender", %{"id" => sender_id}, socket) do
    senders = Enum.reject(socket.assigns.senders_config, &(&1.id == sender_id))

    senders =
      if senders == [],
        do: [%{id: generate_id(), phone_id: nil, template_ids: [], mps: @default_mps}],
        else: senders

    {:noreply, assign(socket, senders_config: senders)}
  end

  @impl true
  def handle_event("select_phone", params, socket) do
    sender_id = params["sender-id"]
    phone_id_str = params["phone-id"]
    phone_id = if phone_id_str in [nil, ""], do: nil, else: String.to_integer(phone_id_str)

    if phone_id && phone_selected_elsewhere?(socket.assigns.senders_config, sender_id, phone_id) do
      {:noreply, assign(socket, error: "That phone is already assigned to another sender")}
    else
      senders =
        Enum.map(socket.assigns.senders_config, fn sender ->
          if sender.id == sender_id do
            %{sender | phone_id: phone_id, template_ids: []}
          else
            sender
          end
        end)

      {:noreply, assign(socket, senders_config: senders, error: nil)}
    end
  end

  @impl true
  def handle_event(
        "toggle_sender_template",
        %{"sender-id" => sender_id, "template-id" => template_id},
        socket
      ) do
    template_id = String.to_integer(template_id)

    senders =
      Enum.map(socket.assigns.senders_config, fn sender ->
        if sender.id == sender_id do
          new_templates =
            if template_id in sender.template_ids do
              List.delete(sender.template_ids, template_id)
            else
              sender.template_ids ++ [template_id]
            end

          %{sender | template_ids: new_templates}
        else
          sender
        end
      end)

    {:noreply, assign(socket, senders_config: senders)}
  end

  @impl true
  def handle_event("toggle_template", %{"id" => _id}, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle_phone", %{"id" => _id}, socket), do: {:noreply, socket}

  @impl true
  def handle_event("start", params, socket) do
    campaign_params = params["campaign"] || %{}
    name = campaign_params["name"] || socket.assigns.campaign_name
    socket = update_senders_from_params(socket, params)
    senders_config = socket.assigns.senders_config

    valid_senders =
      Enum.filter(senders_config, fn s ->
        s.phone_id != nil and length(s.template_ids) > 0
      end)

    duplicate_phones = duplicate_phone_ids(valid_senders)

    cond do
      String.trim(name) == "" ->
        {:noreply, assign(socket, error: "Campaign name is required")}

      duplicate_phones != [] ->
        {:noreply,
         assign(socket, error: "Duplicate phone selected: #{Enum.join(duplicate_phones, ", ")}")}

      Enum.empty?(valid_senders) ->
        {:noreply,
         assign(socket, error: "Please configure at least one sender with phone and templates")}

      true ->
        socket = assign(socket, saving: true, error: nil)
        do_start_retry(socket, name, valid_senders)
    end
  end

  defp update_senders_from_params(socket, params) do
    senders =
      Enum.map(socket.assigns.senders_config, fn sender ->
        mps_key = "mps-#{sender.id}"
        new_mps = parse_mps(params[mps_key], sender.mps || @default_mps)
        %{sender | mps: new_mps}
      end)

    assign(socket, senders_config: senders)
  end

  defp do_start_retry(socket, name, senders_config) do
    alias TitanFlow.Campaigns.Orchestrator

    campaign = socket.assigns.campaign

    storable_config =
      Enum.map(senders_config, fn s ->
        %{
          "phone_id" => s.phone_id,
          "template_ids" => Enum.sort(s.template_ids),
          "mps" => s.mps || @default_mps
        }
      end)

    phone_ids = Enum.map(senders_config, & &1.phone_id) |> Enum.uniq()
    all_template_ids = Enum.flat_map(senders_config, & &1.template_ids) |> Enum.uniq()
    [primary_template_id | fallback_ids] = all_template_ids
    fallback_template_id = List.first(fallback_ids)

    {:ok, updated_campaign} =
      Campaigns.update_campaign(campaign, %{
        name: name,
        senders_config: storable_config,
        primary_template_id: primary_template_id,
        fallback_template_id: fallback_template_id,
        phone_ids: phone_ids,
        template_ids: all_template_ids,
        error_message: nil,
        completed_at: nil
      })

    Logger.info("Retry: Starting retry for campaign #{campaign.id}")

    Task.start(fn ->
      Orchestrator.retry_failed_contacts(updated_campaign.id)
    end)

    {:noreply,
     socket
     |> put_flash(:info, "Retry started for '#{name}'. Pre-flight verification in progress.")
     |> push_navigate(to: ~p"/campaigns")}
  end

  defp parse_mps(nil, fallback), do: fallback
  defp parse_mps("", fallback), do: fallback
  defp parse_mps(val, _fallback) when is_integer(val), do: clamp_mps(val)

  defp parse_mps(val, fallback) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> clamp_mps(n)
      :error -> fallback
    end
  end

  defp clamp_mps(mps) when is_integer(mps) do
    mps
    |> max(10)
    |> min(500)
  end

  defp phone_selected_elsewhere?(senders_config, sender_id, phone_id) do
    Enum.any?(senders_config, fn sender ->
      sender.id != sender_id and sender.phone_id == phone_id
    end)
  end

  defp duplicate_phone_ids(senders_config) do
    senders_config
    |> Enum.map(& &1.phone_id)
    |> Enum.reject(&is_nil/1)
    |> Enum.group_by(& &1)
    |> Enum.filter(fn {_phone_id, list} -> length(list) > 1 end)
    |> Enum.map(fn {phone_id, _} -> to_string(phone_id) end)
  end

  defp format_datetime(nil), do: "-"

  defp format_datetime(datetime) do
    TitanFlowWeb.DateTimeHelpers.format_datetime(datetime)
  end

  defp generate_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

  defp templates_for_phone(all_templates, phone_id, phone_numbers) do
    phone = Enum.find(phone_numbers, &(&1.id == phone_id))

    if phone do
      Enum.filter(all_templates, fn t ->
        t.phone_number_id == phone.id and t.status == "APPROVED" and t.category == "UTILITY"
      end)
    else
      []
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header title="Retry Failed Contacts" />

    <div class="max-w-4xl mx-auto">
      <div class="bg-zinc-900 rounded-lg border border-zinc-800 p-5">
        <div class="mb-5 p-4 bg-amber-500/10 border border-amber-500/30 rounded-lg">
          <div class="flex items-center gap-2 mb-2">
            <span class="text-amber-400 text-lg">!</span>
            <span class="font-medium text-amber-300">Retry Mode</span>
          </div>
          <div class="text-sm text-amber-400">
            <p>Failed and unsent contacts will be retried with the configuration below.</p>
            <p class="text-xs mt-1 text-amber-500">
              Last run failed: <span class="font-mono font-bold"><%= @campaign.failed_count || 0 %></span>
            </p>
            <p class="text-xs mt-1 text-amber-500">
              Campaign created on <%= format_datetime(@campaign.inserted_at) %>
            </p>
          </div>
        </div>

        <%= if @error do %>
          <div class="mb-5 p-4 bg-red-500/10 border border-red-500/30 rounded-lg text-red-400 text-sm">
            <%= @error %>
          </div>
        <% end %>

        <.form for={%{}} phx-change="validate" phx-submit="start">
          <div class="space-y-6">
            <div>
              <label class="block text-sm font-medium text-zinc-300 mb-2">
                Campaign Name <span class="text-red-400">*</span>
              </label>
              <input
                type="text"
                name="campaign[name]"
                value={@campaign_name}
                class="w-full h-9 px-3 rounded-md text-sm bg-zinc-900 border border-zinc-800 text-zinc-100 placeholder-zinc-500 hover:border-zinc-700 focus:outline-none focus:ring-1 focus:ring-indigo-500/50 focus:border-indigo-500"
                placeholder="Enter campaign name"
              />
            </div>

            <div>
              <label class="block text-sm font-medium text-zinc-300 mb-2">
                Sender Configuration <span class="text-red-400">*</span>
              </label>
              <p class="text-xs text-zinc-500 mb-4">
                Configure which phone numbers send with which templates. Each phone will rotate through its assigned templates.
              </p>

              <%= if @phone_numbers == [] do %>
                <div class="p-4 bg-amber-500/10 border border-amber-500/30 rounded-lg text-amber-400 text-sm">
                  No phone numbers configured. <.link navigate={~p"/numbers"} class="underline">Add phone numbers</.link> first.
                </div>
              <% else %>
                <div class="space-y-4">
                  <%= for sender <- @senders_config do %>
                    <% available_templates = templates_for_phone(@all_templates, sender.phone_id, @phone_numbers) %>
                    <div class="p-4 rounded-lg border border-zinc-800 bg-zinc-900/50">
                      <div class="flex items-start gap-4">
                        <div class="flex-1">
                          <label class="block text-xs text-zinc-500 mb-1">Phone Number</label>
                          <select
                            id={"phone-select-#{sender.id}"}
                            class="w-full h-9 px-3 rounded-md text-sm bg-zinc-900 border border-zinc-800 text-zinc-100 hover:border-zinc-700 focus:outline-none focus:ring-1 focus:ring-indigo-500/50"
                            phx-hook="PhoneSelect"
                            data-sender-id={sender.id}
                          >
                            <option value="">Select phone...</option>
                            <%= for phone <- @phone_numbers do %>
                              <option value={phone.id} selected={sender.phone_id == phone.id}>
                                <%= phone.display_name || phone.mobile_number || phone.phone_number_id %>
                              </option>
                            <% end %>
                          </select>
                        </div>

                        <div class="w-28">
                          <label class="block text-xs text-zinc-500 mb-1">MPS Required</label>
                          <input
                            type="number"
                            name={"mps-#{sender.id}"}
                            value={sender.mps || @default_mps}
                            min="10"
                            max="500"
                            phx-debounce="300"
                            class="w-full h-9 px-2 rounded-md text-xs bg-zinc-900 border border-zinc-800 text-zinc-100 hover:border-zinc-700 focus:outline-none focus:ring-1 focus:ring-indigo-500/50"
                          />
                        </div>

                        <%= if length(@senders_config) > 1 do %>
                          <button
                            type="button"
                            phx-click="remove_sender"
                            phx-value-id={sender.id}
                            class="mt-5 p-1.5 text-zinc-500 hover:text-red-400 hover:bg-red-500/10 rounded transition-colors"
                            title="Remove sender"
                          >
                            <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12" />
                            </svg>
                          </button>
                        <% end %>
                      </div>

                      <%= if sender.phone_id do %>
                        <div class="mt-3">
                          <label class="block text-xs text-zinc-500 mb-2">
                            Templates (<%= length(sender.template_ids) %> selected)
                          </label>
                          <%= if available_templates == [] do %>
                            <div class="text-xs text-amber-400 bg-amber-500/10 border border-amber-500/30 rounded p-2">
                              No approved templates for this phone. <.link navigate={~p"/templates"} class="underline">Sync templates</.link>.
                            </div>
                          <% else %>
                            <div class="flex flex-wrap gap-2">
                              <%= for template <- available_templates do %>
                                <button
                                  type="button"
                                  phx-click="toggle_sender_template"
                                  phx-value-sender-id={sender.id}
                                  phx-value-template-id={template.id}
                                  class={"px-3 py-1.5 rounded-full text-xs font-medium border transition-colors " <>
                                    if template.id in sender.template_ids,
                                      do: "bg-indigo-500/20 border-indigo-500/50 text-indigo-300",
                                      else: "bg-zinc-800 border-zinc-700 text-zinc-400 hover:border-zinc-600"}
                                >
                                  <%= template.name %>
                                  <%= if template.id in sender.template_ids do %>
                                    <span class="ml-1">OK</span>
                                  <% end %>
                                </button>
                              <% end %>
                            </div>
                          <% end %>
                        </div>
                      <% else %>
                        <div class="mt-3 text-xs text-zinc-500 italic">
                          Select a phone to see available templates
                        </div>
                      <% end %>
                    </div>
                  <% end %>

                  <button
                    type="button"
                    phx-click="add_sender"
                    class="w-full py-2.5 border-2 border-dashed border-zinc-700 rounded-lg text-sm text-zinc-500 hover:border-indigo-500/50 hover:text-indigo-400 transition-colors"
                  >
                    + Add Another Sender
                  </button>
                </div>
              <% end %>
            </div>

            <div class="flex gap-3 pt-5 border-t border-zinc-800">
              <.link
                navigate={~p"/campaigns"}
                class="flex-1 h-9 px-4 border border-zinc-700 text-zinc-300 rounded-md text-center text-sm font-medium flex items-center justify-center hover:bg-zinc-800 transition-colors"
              >
                Cancel
              </.link>
              <button
                type="submit"
                disabled={@saving}
                class="flex-1 h-9 px-4 bg-indigo-600 hover:bg-indigo-500 disabled:bg-indigo-800 disabled:text-indigo-400 text-white rounded-md text-sm font-medium transition-colors"
              >
                <%= if @saving do %>
                  <span class="flex items-center justify-center gap-2">
                    <svg class="animate-spin h-4 w-4" viewBox="0 0 24 24">
                      <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4" fill="none"></circle>
                      <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"></path>
                    </svg>
                    Starting...
                  </span>
                <% else %>
                  Start Retry
                <% end %>
              </button>
            </div>
          </div>
        </.form>
      </div>
    </div>
    """
  end
end
