defmodule TitanFlowWeb.CampaignsLive do
  use TitanFlowWeb, :live_view

  alias TitanFlow.Campaigns
  alias TitanFlowWeb.DateTimeHelpers

  @per_page 10
  @queue_check_interval_ms 10_000
  @webhook_queue_warn_threshold 10_000

  @impl true
  def mount(_params, _session, socket) do
    page_data = Campaigns.list_campaigns(1, @per_page)

    queue_depth = Campaigns.webhook_queue_depth()
    running_campaigns? = Campaigns.running_campaigns?()

    if connected?(socket) do
      Process.send_after(self(), :queue_tick, @queue_check_interval_ms)
    end

    {:ok,
     assign(socket,
       current_path: "/campaigns",
       campaigns: page_data.entries,
       page: page_data.page,
       total_pages: page_data.total_pages,
       total: page_data.total,
       selected_campaign: nil,
       retrying_campaigns: MapSet.new(),
       webhook_queue_depth: queue_depth,
       running_campaigns?: running_campaigns?,
       webhook_queue_warn_threshold: @webhook_queue_warn_threshold
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header title="Campaigns">
      <:actions>
        <.link navigate={~p"/campaigns/new"} class="inline-flex items-center justify-center gap-2 h-8 px-3 rounded text-sm font-medium bg-indigo-600 hover:bg-indigo-500 text-white transition-colors">
          + New Campaign
        </.link>
      </:actions>
    </.page_header>

    <%= if @selected_campaign == nil and @webhook_queue_depth >= @webhook_queue_warn_threshold and @running_campaigns? do %>
      <div class="mb-4 rounded-lg border border-amber-500/40 bg-amber-500/10 px-4 py-3 text-sm text-amber-300">
        Warning: Webhook queue backlog is high at
        <span class="font-mono font-medium"><%= @webhook_queue_depth %></span>.
      </div>
    <% end %>

    <%= if @campaigns == [] do %>
      <div class="bg-zinc-900 rounded-lg border border-zinc-800">
        <div class="p-6">
          <p class="text-zinc-500">No campaigns yet. Create your first campaign to get started.</p>
        </div>
      </div>
    <% else %>
      <div class="bg-zinc-900 rounded-lg border border-zinc-800 overflow-hidden">
        <table class="min-w-full">
          <thead>
            <tr class="border-b border-zinc-800 bg-zinc-900/50">
              <th class="px-4 py-2 text-left text-xs font-medium text-zinc-400 uppercase tracking-wider">Name</th>
              <th class="px-4 py-2 text-left text-xs font-medium text-zinc-400 uppercase tracking-wider">Status</th>
              <th class="px-4 py-2 text-left text-xs font-medium text-zinc-400 uppercase tracking-wider">Progress</th>
              <th class="px-4 py-2 text-left text-xs font-medium text-zinc-400 uppercase tracking-wider">Sent</th>
              <th class="px-4 py-2 text-left text-xs font-medium text-zinc-400 uppercase tracking-wider">Delivered</th>
              <th class="px-4 py-2 text-left text-xs font-medium text-zinc-400 uppercase tracking-wider">Read</th>
              <th class="px-4 py-2 text-left text-xs font-medium text-zinc-400 uppercase tracking-wider">Failed</th>
              <th class="px-4 py-2 text-left text-xs font-medium text-zinc-400 uppercase tracking-wider">Created</th>
              <th class="px-4 py-2 text-left text-xs font-medium text-zinc-400 uppercase tracking-wider">Actions</th>
            </tr>
          </thead>
          <tbody class="divide-y divide-zinc-800">
            <%= for campaign <- @campaigns do %>
              <tr 
                phx-click="show_stats" 
                phx-value-id={campaign.id} 
                class="hover:bg-zinc-800/50 transition-colors cursor-pointer"
              >
                <td class="px-4 py-2 whitespace-nowrap">
                  <div class="text-sm font-medium text-zinc-100"><%= campaign.name %></div>
                  <div class="text-xs text-zinc-500 font-mono">
                    <%= if campaign.primary_template, do: campaign.primary_template.name, else: "-" %>
                  </div>
                </td>
                <td class="px-4 py-2 whitespace-nowrap">
                  <% retrying = MapSet.member?(@retrying_campaigns, campaign.id) %>
                  <span class={status_badge_class(if retrying, do: "retrying", else: campaign.status)}>
                    <%= if retrying, do: "retrying", else: campaign.status %>
                  </span>
                </td>
                <td class="px-4 py-2 whitespace-nowrap">
                  <div class="flex items-center gap-2">
                    <div class="w-20 bg-zinc-800 rounded-full h-1.5">
                      <div class="bg-indigo-500 h-1.5 rounded-full" style={"width: #{progress_percent(campaign)}%"}></div>
                    </div>
                    <span class="text-xs text-zinc-500 font-mono">
                      <%= (campaign.sent_count || 0) + (campaign.failed_count || 0) %>/<%= campaign.total_records || 0 %>
                    </span>
                  </div>
                </td>
                <td class="px-4 py-2 whitespace-nowrap text-sm">
                  <span class="text-blue-400 font-mono font-medium"><%= campaign.sent_count || 0 %></span>
                </td>
                <td class="px-4 py-2 whitespace-nowrap text-sm">
                  <span class="text-emerald-400 font-mono font-medium"><%= campaign.delivered_count || 0 %></span>
                </td>
                <td class="px-4 py-2 whitespace-nowrap text-sm">
                  <span class="text-violet-400 font-mono font-medium"><%= campaign.read_count || 0 %></span>
                </td>
                <td class="px-4 py-2 whitespace-nowrap text-sm">
                  <span class="text-red-400 font-mono font-medium"><%= campaign.failed_count || 0 %></span>
                </td>
                <td class="px-4 py-2 whitespace-nowrap text-sm text-zinc-500 font-mono">
                  <%= format_datetime(campaign.inserted_at) %>
                </td>
                <td class="px-4 py-2 whitespace-nowrap text-sm">
                  <%= if campaign.status == "draft" do %>
                    <div class="flex gap-2" phx-click="" phx-value-id="">
                      <.link 
                        navigate={~p"/campaigns/#{campaign.id}/resume"}
                        class="h-7 px-2.5 rounded text-xs font-medium inline-flex items-center bg-indigo-600 hover:bg-indigo-500 text-white transition-colors"
                      >
                        Resume
                      </.link>
                      <button
                        type="button"
                        phx-click="delete_draft"
                        phx-value-id={campaign.id}
                        onclick={"if(!confirm('Delete this draft campaign and all its contacts?')) { event.stopPropagation(); return false; }"}
                        class="h-7 px-2.5 rounded text-xs font-medium bg-red-600 hover:bg-red-500 text-white transition-colors"
                      >
                        Delete
                      </button>
                    </div>
                  <% else %>
                    <span class="text-zinc-600">-</span>
                  <% end %>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
      
      <%!-- Pagination Controls --%>
      <%= if @total_pages > 1 do %>
        <div class="mt-4 flex items-center justify-between">
          <div class="text-sm text-zinc-500">
            Showing <%= length(@campaigns) %> of <%= @total %> campaigns
          </div>
          <div class="flex gap-2">
            <button
              type="button"
              phx-click="prev_page"
              disabled={@page <= 1}
              class={"h-8 px-3 rounded text-sm font-medium transition-colors " <>
                if @page <= 1, 
                  do: "bg-zinc-800 text-zinc-600 cursor-not-allowed", 
                  else: "bg-zinc-800 text-zinc-300 hover:bg-zinc-700 border border-zinc-700"}
            >
              ← Previous
            </button>
            <span class="h-8 px-3 flex items-center text-sm text-zinc-400 font-mono">
              <%= @page %> / <%= @total_pages %>
            </span>
            <button
              type="button"
              phx-click="next_page"
              disabled={@page >= @total_pages}
              class={"h-8 px-3 rounded text-sm font-medium transition-colors " <>
                if @page >= @total_pages, 
                  do: "bg-zinc-800 text-zinc-600 cursor-not-allowed", 
                  else: "bg-zinc-800 text-zinc-300 hover:bg-zinc-700 border border-zinc-700"}
            >
              Next →
            </button>
          </div>
        </div>
      <% end %>
    <% end %>

    <%= if @selected_campaign do %>
      <.stats_modal
        campaign={@selected_campaign}
        stats={@live_stats}
        template_stats={@template_stats}
        failed_breakdown={@failed_breakdown}
        mps={@current_mps}
        retrying={MapSet.member?(@retrying_campaigns, @selected_campaign.id)}
        webhook_queue_depth={@webhook_queue_depth}
        phone_statuses={@phone_statuses}
      />
    <% end %>
    """
  end

  @impl true
  def handle_event("show_stats", %{"id" => id}, socket) do
    require Logger
    Logger.info("DEBUG: show_stats clicked for id #{id}")
    campaign = Campaigns.get_campaign!(id)
    queue_depth = Campaigns.webhook_queue_depth()
    running_campaigns? = Campaigns.running_campaigns?()
    phone_statuses = Campaigns.phone_statuses(campaign.id)
    # Start polling if running
    if connected?(socket), do: Process.send_after(self(), :tick, 2000)

    cached_stats = %{
      sent_count: campaign.sent_count || 0,
      delivered_count: campaign.delivered_count || 0,
      read_count: campaign.read_count || 0,
      replied_count: campaign.replied_count || 0,
      failed_count: campaign.failed_count || 0
    }

    load_campaign_stats_async(campaign.id)

    {:noreply,
     assign(socket,
       selected_campaign: campaign,
       live_stats: cached_stats,
       template_stats: nil,
       template_stats_updated_at: campaign.updated_at,
       failed_breakdown: [],
       failed_breakdown_updated_at: campaign.updated_at,
        current_mps: 0.0,
        phone_statuses: phone_statuses,
        webhook_queue_depth: queue_depth,
        running_campaigns?: running_campaigns?
      )}
  end

  @impl true
  def handle_info(
        {:campaign_stats_loaded, campaign_id, campaign, stats, template_stats, failed_breakdown},
        socket
      ) do
    if socket.assigns.selected_campaign &&
         socket.assigns.selected_campaign.id == campaign_id do
      {:noreply,
       assign(socket,
         selected_campaign: campaign,
         live_stats: stats,
         template_stats: template_stats,
         template_stats_updated_at: campaign.updated_at,
         failed_breakdown: failed_breakdown,
         failed_breakdown_updated_at: campaign.updated_at
       )}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("close_stats", _, socket) do
    {:noreply, assign(socket, selected_campaign: nil)}
  end

  @impl true
  def handle_event("pause_campaign", %{"id" => id}, socket) do
    alias TitanFlow.Campaigns.Orchestrator

    case Orchestrator.pause_campaign(String.to_integer(id)) do
      {:ok, _} ->
        page_data = Campaigns.list_campaigns(socket.assigns.page, @per_page)
        campaign = Campaigns.get_campaign!(id)

        {:noreply,
         socket
         |> assign(campaigns: page_data.entries, selected_campaign: campaign)
         |> put_flash(:info, "Campaign paused")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to pause campaign")}
    end
  end

  @impl true
  def handle_event("resume_campaign", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/campaigns/#{id}/resume")}
  end

  @impl true
  def handle_event("retry_failed", %{"id" => id}, socket) do
    alias TitanFlow.Campaigns.Orchestrator
    campaign_id = String.to_integer(id)

    # Start retry in background task to not block UI
    caller = self()

    Task.start(fn ->
      result = Orchestrator.retry_failed_contacts(campaign_id)
      send(caller, {:retry_failed_result, campaign_id, result})
    end)

    page_data = Campaigns.list_campaigns(socket.assigns.page, @per_page)
    campaign = Campaigns.get_campaign!(id)

    Process.send_after(self(), :refresh_campaigns, 2_000)

    {:noreply,
     socket
     |> assign(
       campaigns: page_data.entries,
       selected_campaign: campaign,
       retrying_campaigns: MapSet.put(socket.assigns.retrying_campaigns, campaign_id)
     )
     |> put_flash(:info, "Retrying failed contacts... Templates synced and campaign restarted.")}
  end

  @impl true
  def handle_event("delete_draft", %{"id" => id}, socket) do
    id = String.to_integer(id)
    campaign = Campaigns.get_campaign!(id)

    if campaign.status == "draft" do
      # Delete contacts first (FK constraint)
      import Ecto.Query
      TitanFlow.Repo.delete_all(from c in "contacts", where: c.campaign_id == ^id)

      # Delete campaign
      Campaigns.delete_campaign(campaign)

      # Refresh list with pagination
      page_data = Campaigns.list_campaigns(socket.assigns.page, @per_page)

      {:noreply,
       socket
       |> assign(
         campaigns: page_data.entries,
         total: page_data.total,
         total_pages: page_data.total_pages
       )
       |> put_flash(:info, "Draft campaign deleted")}
    else
      {:noreply, put_flash(socket, :error, "Can only delete draft campaigns")}
    end
  end

  @impl true
  def handle_event("prev_page", _, socket) do
    new_page = max(1, socket.assigns.page - 1)
    page_data = Campaigns.list_campaigns(new_page, @per_page)

    {:noreply,
     assign(socket,
       campaigns: page_data.entries,
       page: page_data.page,
       total_pages: page_data.total_pages,
       total: page_data.total
     )}
  end

  @impl true
  def handle_event("next_page", _, socket) do
    new_page = min(socket.assigns.total_pages, socket.assigns.page + 1)
    page_data = Campaigns.list_campaigns(new_page, @per_page)

    {:noreply,
     assign(socket,
       campaigns: page_data.entries,
       page: page_data.page,
       total_pages: page_data.total_pages,
       total: page_data.total
     )}
  end

  @impl true
  def handle_info(:tick, socket) do
    if socket.assigns.selected_campaign do
      # 10 second polling interval
      Process.send_after(self(), :tick, 10_000)

      # Reload campaign to check for status updates / timestamps
      campaign_id = socket.assigns.selected_campaign.id
      campaign = Campaigns.get_campaign!(campaign_id)

      new_stats = TitanFlow.Campaigns.MessageTracking.get_realtime_stats(campaign_id)
      phone_statuses = Campaigns.phone_statuses(campaign_id)

      {template_stats, template_stats_updated_at} =
        if campaign.status == "completed" and
             socket.assigns[:template_stats_updated_at] != campaign.updated_at do
          {
            TitanFlow.Campaigns.MessageTracking.get_template_breakdown(campaign.id),
            campaign.updated_at
          }
        else
          {
            socket.assigns[:template_stats],
            socket.assigns[:template_stats_updated_at]
          }
        end

      # Calculate MPS based on 10 second interval
      old_sent = socket.assigns.live_stats.sent_count || 0
      new_sent = new_stats.sent_count || 0
      mps = max(0.0, (new_sent - old_sent) / 10.0)

      current_failed_count = new_stats.failed_count || 0
      previous_failed_count = socket.assigns.live_stats.failed_count || 0
      failed_count_changed = current_failed_count != previous_failed_count

      {failed_breakdown, failed_breakdown_updated_at} =
        cond do
          current_failed_count == 0 ->
            {[], campaign.updated_at}

          failed_count_changed or
              socket.assigns[:failed_breakdown_updated_at] != campaign.updated_at ->
            {
              TitanFlow.Campaigns.MessageTracking.get_failed_breakdown(campaign.id),
              campaign.updated_at
            }

          true ->
            {
              socket.assigns[:failed_breakdown] || [],
              socket.assigns[:failed_breakdown_updated_at]
            }
        end

      {:noreply,
       assign(socket,
         selected_campaign: campaign,
         live_stats: new_stats,
         template_stats: template_stats,
         template_stats_updated_at: template_stats_updated_at,
         current_mps: mps,
         phone_statuses: phone_statuses,
         failed_breakdown: failed_breakdown,
         failed_breakdown_updated_at: failed_breakdown_updated_at
       )}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:queue_tick, socket) do
    queue_depth = Campaigns.webhook_queue_depth()
    running_campaigns? = Campaigns.running_campaigns?()

    Process.send_after(self(), :queue_tick, @queue_check_interval_ms)

    {:noreply,
     assign(socket,
       webhook_queue_depth: queue_depth,
       running_campaigns?: running_campaigns?
     )}
  end

  @impl true
  def handle_info({:retry_failed_result, campaign_id, result}, socket) do
    socket =
      case result do
        {:ok, :retry_started} ->
          socket

        {:error, reason} ->
          socket
          |> assign(
            retrying_campaigns: MapSet.delete(socket.assigns.retrying_campaigns, campaign_id)
          )
          |> put_flash(:error, "Retry failed to start: #{inspect(reason)}")

        _ ->
          socket
          |> assign(
            retrying_campaigns: MapSet.delete(socket.assigns.retrying_campaigns, campaign_id)
          )
          |> put_flash(:error, "Retry failed to start")
      end

    if MapSet.size(socket.assigns.retrying_campaigns) > 0 do
      Process.send_after(self(), :refresh_campaigns, 2_000)
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info(:refresh_campaigns, socket) do
    page_data = Campaigns.list_campaigns(socket.assigns.page, @per_page)

    {retrying_campaigns, completed_names} =
      update_retrying_campaigns(socket.assigns.retrying_campaigns, page_data.entries)

    socket =
      socket
      |> assign(
        campaigns: page_data.entries,
        page: page_data.page,
        total_pages: page_data.total_pages,
        total: page_data.total,
        retrying_campaigns: retrying_campaigns
      )

    socket =
      case completed_names do
        [] ->
          socket

        [name] ->
          put_flash(socket, :info, "Retry completed for #{name}")

        names ->
          put_flash(socket, :info, "Retries completed for #{length(names)} campaigns")
      end

    if MapSet.size(retrying_campaigns) > 0 do
      Process.send_after(self(), :refresh_campaigns, 3_000)
    end

    {:noreply, socket}
  end

  defp status_badge_class(status) do
    base = "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium"

    case status do
      "draft" -> "#{base} bg-zinc-700/50 text-zinc-400 border border-zinc-700"
      "pending" -> "#{base} bg-amber-500/20 text-amber-400 border border-amber-500/30"
      "running" -> "#{base} bg-blue-500/20 text-blue-400 border border-blue-500/30"
      "retrying" -> "#{base} bg-orange-500/20 text-orange-400 border border-orange-500/30"
      "completed" -> "#{base} bg-emerald-500/20 text-emerald-400 border border-emerald-500/30"
      "failed" -> "#{base} bg-red-500/20 text-red-400 border border-red-500/30"
      "paused" -> "#{base} bg-zinc-700/50 text-zinc-400 border border-zinc-700"
      "error" -> "#{base} bg-red-500/20 text-red-400 border border-red-500/30"
      _ -> "#{base} bg-zinc-700/50 text-zinc-400 border border-zinc-700"
    end
  end

  defp load_campaign_stats_async(campaign_id) do
    caller = self()

    Task.start(fn ->
      require Logger

      try do
        campaign = Campaigns.get_campaign!(campaign_id)
        stats = TitanFlow.Campaigns.MessageTracking.get_realtime_stats(campaign_id)

        updated_campaign =
          case Campaigns.update_campaign(campaign, %{
                 sent_count: stats.sent_count,
                 delivered_count: stats.delivered_count,
                 read_count: stats.read_count,
                 replied_count: stats.replied_count,
                 failed_count: stats.failed_count
               }) do
            {:ok, updated} -> updated
            _ -> campaign
          end

        template_stats =
          if updated_campaign.status == "completed" do
            TitanFlow.Campaigns.MessageTracking.get_template_breakdown(campaign_id)
          else
            nil
          end

        failed_breakdown =
          if (stats.failed_count || 0) > 0 do
            TitanFlow.Campaigns.MessageTracking.get_failed_breakdown(campaign_id)
          else
            []
          end

        send(
          caller,
          {:campaign_stats_loaded, campaign_id, updated_campaign, stats, template_stats,
           failed_breakdown}
        )
      rescue
        error ->
          Logger.warning(
            "Failed to load campaign stats async for #{campaign_id}: #{inspect(error)}"
          )
      end
    end)
  end

  defp update_retrying_campaigns(retrying_campaigns, campaigns) do
    {completed_ids, completed_names} =
      retrying_campaigns
      |> Enum.reduce({[], []}, fn campaign_id, {ids, names} ->
        case Enum.find(campaigns, &(&1.id == campaign_id)) do
          nil ->
            {ids, names}

          campaign when campaign.status in ["completed", "paused"] ->
            {[campaign.id | ids], [campaign.name | names]}

          _ ->
            {ids, names}
        end
      end)

    updated_retrying =
      Enum.reduce(completed_ids, retrying_campaigns, fn campaign_id, acc ->
        MapSet.delete(acc, campaign_id)
      end)

    {updated_retrying, Enum.reverse(completed_names)}
  end

  defp format_datetime(nil), do: "-"

  defp format_datetime(datetime) do
    TitanFlowWeb.DateTimeHelpers.format_datetime(datetime)
  end

  defp format_ms_timestamp(nil), do: "-"

  defp format_ms_timestamp(ms) do
    ms
    |> DateTime.from_unix!(:millisecond)
    |> TitanFlowWeb.DateTimeHelpers.format_datetime_with_seconds()
  end

  defp progress_percent(campaign) do
    total = campaign.total_records || 0
    processed = (campaign.sent_count || 0) + (campaign.failed_count || 0)

    if total > 0 do
      round(processed / total * 100)
    else
      0
    end
  end

  defp stats_modal(assigns) do
    # Smart Stats Logic
    raw = assigns.stats

    # NOTE: delivered_count from get_realtime_stats ALREADY includes read 
    # (it's calculated as delivered + read statuses), so don't add again!
    effective_delivered = raw.delivered_count

    # Read count is already accurate from get_realtime_stats
    effective_read = raw.read_count

    replied = raw.replied_count
    sent = raw.sent_count

    # Calculate percentages
    pct = fn val ->
      if sent > 0, do: Float.round(val / sent * 100, 1), else: 0.0
    end

    # Calculate Duration and Avg Speed
    {duration_str, avg_speed} =
      if assigns.campaign.status == "completed" && assigns.campaign.started_at &&
           assigns.campaign.completed_at do
        duration = NaiveDateTime.diff(assigns.campaign.completed_at, assigns.campaign.started_at)
        speed = if duration > 0, do: raw.sent_count / duration, else: 0.0

        hours = div(duration, 3600)
        minutes = div(rem(duration, 3600), 60)
        seconds = rem(duration, 60)

        dur_str =
          cond do
            hours > 0 -> "#{hours}h #{minutes}m"
            minutes > 0 -> "#{minutes}m #{seconds}s"
            true -> "#{seconds}s"
          end

        {dur_str, speed}
      else
        {"-", 0.0}
      end

    alias TitanFlowWeb.DateTimeHelpers

    phone_statuses = assigns[:phone_statuses] || []

    active_phone_statuses =
      Enum.filter(phone_statuses, fn status ->
        status.exhausted or status.paused_until_ms
      end)

    campaign_started_at =
      if assigns.campaign.started_at,
        do: DateTimeHelpers.format_datetime_with_seconds(assigns.campaign.started_at),
        else: "-"

    campaign_completed_at =
      if assigns.campaign.completed_at,
        do: DateTimeHelpers.format_datetime_with_seconds(assigns.campaign.completed_at),
        else: "-"

    queue_warn = assigns.webhook_queue_depth >= @webhook_queue_warn_threshold
    failed_breakdown = assigns[:failed_breakdown] || []

    assigns =
      assigns
      |> assign(:eff_delivered, effective_delivered)
      |> assign(:eff_read, effective_read)
      |> assign(:replied, replied)
      |> assign(:pct_delivered, pct.(effective_delivered))
      |> assign(:pct_read, pct.(effective_read))
      |> assign(:pct_replied, pct.(replied))
      |> assign(:duration_str, duration_str)
      |> assign(:avg_speed, avg_speed)
      |> assign(:started_at, campaign_started_at)
      |> assign(:completed_at, campaign_completed_at)
      |> assign(:webhook_queue_warn, queue_warn)
      |> assign(:active_phone_statuses, active_phone_statuses)
      |> assign(:failed_breakdown, failed_breakdown)

    ~H"""
    <div class="fixed inset-0 z-50 flex items-center justify-center bg-black/70 backdrop-blur-sm" phx-click="close_stats">
      <div class="bg-zinc-900 border border-zinc-800 rounded-xl shadow-2xl w-full max-w-2xl m-4 overflow-hidden max-h-[90vh] overflow-y-auto" phx-click-away="close_stats" phx-click-stop>
        <!-- Header -->
        <div class="px-6 py-4 border-b border-zinc-800 flex items-center justify-between sticky top-0 bg-zinc-900 z-10">
          <div>
            <h2 class="text-lg font-semibold text-zinc-100"><%= @campaign.name %></h2>
            <div class="flex items-center gap-3 text-sm text-zinc-500">
               <span><%= @campaign.status %></span>
               <span>•</span>
               <%= if @campaign.status == "completed" do %>
                 <span>Avg: <span class="font-mono text-indigo-400 font-medium"><%= Float.round(@avg_speed, 1) %> msg/s</span></span>
                 <span>•</span>
                 <span>Duration: <span class="font-mono text-zinc-300"><%= @duration_str %></span></span>
               <% else %>
                 <span>Real-time: <span class="font-mono text-indigo-400 font-medium"><%= Float.round(@mps, 1) %> msg/s</span></span>
               <% end %>
               <span>•</span>
               <span>
                 Webhook queue:
                 <span class={"font-mono font-medium " <> if @webhook_queue_warn, do: "text-amber-400", else: "text-zinc-300"}>
                   <%= @webhook_queue_depth %>
                 </span>
               </span>
               <%= if @retrying do %>
                 <span>•</span>
                 <span class="text-orange-400 font-medium">Retry in progress</span>
               <% end %>
            </div>
          </div>
          <button phx-click="close_stats" class="text-zinc-500 hover:text-zinc-300 transition-colors p-1">
            <span class="text-xl">×</span>
          </button>
        </div>
        
        <div class="p-6 space-y-5">
          <%= if @campaign.error_message && String.trim(@campaign.error_message) != "" do %>
            <div class="bg-amber-500/10 rounded-lg p-4 border border-amber-500/30">
              <div class="text-sm font-medium text-amber-300">Remarks</div>
              <div class="text-xs text-amber-400/80 mt-1">
                <%= @campaign.error_message %>
              </div>
            </div>
          <% end %>
          <!-- Timeline & Progress -->
          <div class="bg-zinc-800/50 rounded-lg p-4 space-y-3 border border-zinc-800">
             <div class="flex justify-between text-xs text-zinc-500">
                <span>Started: <span class="font-mono text-zinc-400"><%= @started_at %></span></span>
                <span>Ended: <span class="font-mono text-zinc-400"><%= @completed_at %></span></span>
             </div>
             <!-- Progress Bar -->
             <div class="w-full bg-zinc-700 rounded-full h-1.5">
                <div class="bg-indigo-500 h-1.5 rounded-full transition-all duration-500" style={"width: #{progress_percent(@campaign)}%"}></div>
             </div>
             <div class="text-right text-xs font-medium text-indigo-400">
                <%= progress_percent(@campaign) %>% Complete
             </div>
          </div>

          <!-- Deduplication Notice -->
          <%= if @campaign.skipped_count && @campaign.skipped_count > 0 do %>
            <div class="bg-amber-500/10 rounded-lg p-4 border border-amber-500/30">
              <div class="flex items-start gap-3">
                <span class="text-amber-400 text-lg">⚠️</span>
                <div class="flex-1">
                  <div class="text-sm font-medium text-amber-300 mb-1">
                    <span class="font-bold font-mono text-base"><%= @campaign.skipped_count %></span> Duplicate Contacts Removed
                  </div>
                  <div class="text-xs text-amber-400/80">
                    These numbers were already contacted within the last <%= @campaign.dedup_window_days %> day<%= if @campaign.dedup_window_days > 1, do: "s", else: "" %> and excluded from this campaign.
                  </div>
                  <div class="text-xs text-amber-300/70 mt-1.5">
                    Final contact list: <span class="font-mono font-medium"><%= @campaign.total_records %></span> contacts
                  </div>
                </div>
              </div>
            </div>
          <% end %>

          <%= if Enum.any?(@active_phone_statuses) do %>
            <div class="bg-zinc-800/50 rounded-lg p-4 border border-zinc-800">
              <div class="text-sm font-medium text-zinc-300">Phone Status</div>
              <div class="mt-2 space-y-2">
                <%= for status <- @active_phone_statuses do %>
                  <div class="flex items-center justify-between text-xs">
                    <div class="text-zinc-300">
                      <%= status.display_name || status.phone_number_id %>
                      <span class="text-zinc-500">(<%= status.phone_number_id %>)</span>
                    </div>
                    <div class="text-right">
                      <%= if status.exhausted do %>
                        <span class="text-red-400 font-medium">Exhausted</span>
                      <% else %>
                        <span class="text-amber-400 font-medium">Paused (131048 threshold)</span>
                        <span class="text-zinc-500 ml-1">until <%= format_ms_timestamp(status.paused_until_ms) %></span>
                      <% end %>
                    </div>
                  </div>
                <% end %>
              </div>
            </div>
          <% end %>

          <!-- Stats Grid -->
          <div class="grid grid-cols-2 gap-3">
            <!-- Sent -->
            <div class="bg-blue-500/10 p-4 rounded-lg border border-blue-500/30">
              <p class="text-sm font-medium text-blue-400">Total Sent</p>
              <p class="text-2xl font-bold text-blue-300 font-mono"><%= @stats.sent_count %></p>
              <p class="text-xs text-blue-500/80 mt-1">Target: <span class="font-mono"><%= @campaign.total_records %></span></p>
            </div>
            
            <!-- Delivered (Smart) -->
            <div class="bg-emerald-500/10 p-4 rounded-lg border border-emerald-500/30">
              <p class="text-sm font-medium text-emerald-400">Delivered</p>
              <p class="text-2xl font-bold text-emerald-300 font-mono"><%= @eff_delivered %></p>
              <p class="text-xs text-emerald-500/80 mt-1"><%= @pct_delivered %>%</p>
            </div>
            
            <!-- Read (Smart) -->
            <div class="bg-violet-500/10 p-4 rounded-lg border border-violet-500/30">
              <p class="text-sm font-medium text-violet-400">Read</p>
              <p class="text-2xl font-bold text-violet-300 font-mono"><%= @eff_read %></p>
              <p class="text-xs text-violet-500/80 mt-1"><%= @pct_read %>%</p>
            </div>
            
            <!-- Replied -->
            <div class="bg-pink-500/10 p-4 rounded-lg border border-pink-500/30">
              <p class="text-sm font-medium text-pink-400">Replied</p>
              <p class="text-2xl font-bold text-pink-300 font-mono"><%= @replied %></p>
              <p class="text-xs text-pink-500/80 mt-1"><%= @pct_replied %>%</p>
            </div>
          </div>
          
          <!-- Template Breakdown (Only if completed and available) -->
          <%= if @template_stats && map_size(@template_stats) > 0 do %>
            <div>
               <h3 class="text-xs font-medium text-zinc-400 uppercase tracking-wider mb-3">Template Breakdown</h3>
               <div class="overflow-hidden rounded-lg border border-zinc-800">
                 <table class="min-w-full">
                   <thead>
                     <tr class="border-b border-zinc-800 bg-zinc-800/50">
                       <th class="px-4 py-2 text-left text-xs font-medium text-zinc-400 uppercase">Template</th>
                       <th class="px-4 py-2 text-right text-xs font-medium text-blue-400 uppercase">Sent</th>
                       <th class="px-4 py-2 text-right text-xs font-medium text-emerald-400 uppercase">Delivered</th>
                       <th class="px-4 py-2 text-right text-xs font-medium text-violet-400 uppercase">Read</th>
                       <th class="px-4 py-2 text-right text-xs font-medium text-pink-400 uppercase">Replied</th>
                     </tr>
                   </thead>
                   <tbody class="divide-y divide-zinc-800">
                      <%= for {name, stats} <- @template_stats do %>
                        <% 
                          # Total sent = sum of all statuses (sent + delivered + read + failed)
                          total_sent = Map.get(stats, "sent", 0) + Map.get(stats, "delivered", 0) + Map.get(stats, "read", 0) + Map.get(stats, "failed", 0)
                          # Delivered = delivered + read (read implies delivered)
                          total_delivered = Map.get(stats, "delivered", 0) + Map.get(stats, "read", 0)
                        %>
                        <tr class="text-sm">
                          <td class="px-4 py-2 font-medium text-zinc-100"><%= name || "Unknown" %></td>
                          <td class="px-4 py-2 text-right text-zinc-400 font-mono"><%= total_sent %></td>
                          <td class="px-4 py-2 text-right text-zinc-400 font-mono"><%= total_delivered %></td>
                          <td class="px-4 py-2 text-right text-zinc-400 font-mono"><%= Map.get(stats, "read", 0) %></td>
                          <td class="px-4 py-2 text-right text-zinc-400 font-mono"><%= Map.get(stats, "replied", 0) %></td>
                        </tr>
                      <% end %>
                   </tbody>
                 </table>
               </div>
            </div>
          <% end %>

          <!-- Failed Stats -->
           <div class="bg-red-500/10 p-4 rounded-lg border border-red-500/30 flex items-center justify-between">
             <div>
                <p class="text-sm font-medium text-red-400">Failed Messages</p>
                <div class="flex items-baseline gap-2">
                   <p class="text-xl font-bold text-red-300 font-mono"><%= @stats.failed_count %></p>
                   <p class="text-xs text-red-500/80"><%= if @stats.sent_count > 0, do: Float.round(@stats.failed_count / (@stats.sent_count + @stats.failed_count) * 100, 1), else: 0 %>% failure rate</p>
                </div>
             </div>
           </div>

          <!-- Pause/Resume Buttons -->
          <%= if @campaign.status in ["running", "paused"] do %>
            <div class="flex gap-3">
              <%= if @campaign.status == "running" do %>
                <button 
                  phx-click="pause_campaign" 
                  phx-value-id={@campaign.id}
                  class="flex-1 h-9 px-4 bg-amber-600 hover:bg-amber-500 text-white rounded-md font-medium text-sm transition-colors"
                >
                  ⏸ Pause Campaign
                </button>
              <% else %>
                <button 
                  phx-click="resume_campaign" 
                  phx-value-id={@campaign.id}
                  class="flex-1 h-9 px-4 bg-indigo-600 hover:bg-indigo-500 text-white rounded-md font-medium text-sm transition-colors"
                >
                  ▶ Resume Campaign
                </button>
              <% end %>
            </div>
          <% end %>
          
          <!-- Retry Failed Button (for completed campaigns with failures) -->
          <%= if @campaign.status == "completed" && @stats.failed_count > 0 do %>
            <div class="flex gap-3">
              <button 
                phx-click="retry_failed" 
                phx-value-id={@campaign.id}
                disabled={@retrying}
                class={"flex-1 h-9 px-4 text-white rounded-md font-medium text-sm transition-colors " <>
                  if @retrying, do: "bg-orange-900/60 cursor-not-allowed", else: "bg-orange-600 hover:bg-orange-500"}
              >
                <%= if @retrying do %>
                  ⏳ Retrying...
                <% else %>
                  🔄 Retry Failed (<%= @stats.failed_count %>)
                <% end %>
              </button>
            </div>
          <% end %>

          <!-- Failed Breakdown -->
          <%= if length(@failed_breakdown) > 0 do %>
            <div>
              <h3 class="text-xs font-medium text-zinc-400 uppercase tracking-wider mb-3">Failed Breakdown</h3>
              <div class="overflow-hidden rounded-lg border border-zinc-800 max-h-48 overflow-y-auto">
                <table class="min-w-full">
                  <thead class="sticky top-0">
                    <tr class="border-b border-zinc-800 bg-zinc-800/50">
                      <th class="px-4 py-2 text-left text-xs font-medium text-zinc-400 uppercase">Error Code</th>
                      <th class="px-4 py-2 text-left text-xs font-medium text-zinc-400 uppercase">Error Message</th>
                      <th class="px-4 py-2 text-right text-xs font-medium text-zinc-400 uppercase">Count</th>
                    </tr>
                  </thead>
                  <tbody class="divide-y divide-zinc-800">
                    <%= for row <- @failed_breakdown do %>
                      <tr class="text-sm">
                        <td class="px-4 py-2 font-mono text-zinc-300"><%= row.error_code || "?" %></td>
                        <td class="px-4 py-2 text-zinc-400 text-xs"><%= row.error_message || "-" %></td>
                        <td class="px-4 py-2 text-right text-zinc-400 font-mono"><%= row.count %></td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            </div>
          <% end %>

        </div>
      </div>
    </div>
    """
  end
end
