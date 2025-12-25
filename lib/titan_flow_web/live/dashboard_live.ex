defmodule TitanFlowWeb.DashboardLive do
  use TitanFlowWeb, :live_view

  alias TitanFlow.Campaigns
  alias TitanFlow.WhatsApp
  alias TitanFlow.Templates
  alias TitanFlow.Stats

  @impl true
  def mount(_params, _session, socket) do
    # OPTIMIZED: Use single aggregate query instead of loading all campaigns
    summary = Stats.get_dashboard_summary()

    # OPTIMIZED: Use efficient COUNT queries instead of loading all records
    phone_count = WhatsApp.count_phone_numbers()
    template_count = Templates.count_templates()

    # Only fetch 5 recent campaigns for display (paginated)
    recent_result = Campaigns.list_campaigns(1, 5)
    recent_campaigns = recent_result.entries

    socket =
      socket
      |> assign(current_path: "/dashboard")
      |> assign(active_campaigns: summary.active_count)
      |> assign(total_sent: summary.total_sent)
      |> assign(phone_count: phone_count)
      |> assign(template_count: template_count)
      |> assign(recent_campaigns: recent_campaigns)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header title="Dashboard" />

    <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4">
      <.stat_card title="Active Campaigns" value={@active_campaigns} icon="🚀" />
      <.stat_card title="Messages Sent" value={format_number(@total_sent)} icon="📤" />
      <.stat_card title="Phone Numbers" value={@phone_count} icon="📱" />
      <.stat_card title="Templates" value={@template_count} icon="📄" />
    </div>

    <div class="mt-6">
      <h2 class="text-sm font-medium text-zinc-400 uppercase tracking-wider mb-3">Recent Campaigns</h2>
      <div class="bg-zinc-900 rounded-lg border border-zinc-800 overflow-hidden">
        <%= if @recent_campaigns == [] do %>
          <div class="p-6">
            <p class="text-zinc-500">No campaigns yet. <.link navigate={~p"/campaigns/new"} class="text-indigo-400 hover:text-indigo-300 hover:underline">Create your first campaign</.link></p>
          </div>
        <% else %>
          <table class="min-w-full">
            <thead>
              <tr class="border-b border-zinc-800">
                <th class="px-4 py-2 text-left text-xs font-medium text-zinc-400 uppercase tracking-wider">Name</th>
                <th class="px-4 py-2 text-left text-xs font-medium text-zinc-400 uppercase tracking-wider">Stats</th>
                <th class="px-4 py-2 text-right text-xs font-medium text-zinc-400 uppercase tracking-wider">Status</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-zinc-800">
              <%= for campaign <- @recent_campaigns do %>
                <tr class="hover:bg-zinc-800/50 transition-colors">
                  <td class="px-4 py-3">
                    <p class="font-medium text-zinc-100"><%= campaign.name %></p>
                  </td>
                  <td class="px-4 py-3">
                    <p class="text-sm text-zinc-400 font-mono">
                      <span class="text-blue-400"><%= campaign.sent_count || 0 %></span> sent •
                      <span class="text-emerald-400"><%= campaign.delivered_count || 0 %></span> delivered •
                      <span class="text-violet-400"><%= campaign.read_count || 0 %></span> read
                    </p>
                  </td>
                  <td class="px-4 py-3 text-right">
                    <span class={status_badge_class(campaign.status)}>
                      <%= campaign.status %>
                    </span>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        <% end %>
      </div>
    </div>
    """
  end

  defp format_number(n) when n >= 1000, do: "#{Float.round(n / 1000, 1)}k"
  defp format_number(n), do: to_string(n)

  defp status_badge_class(status) do
    base = "inline-flex items-center px-2 py-0.5 rounded text-xs font-medium"

    case status do
      "pending" -> "#{base} bg-amber-500/20 text-amber-400 border border-amber-500/30"
      "running" -> "#{base} bg-blue-500/20 text-blue-400 border border-blue-500/30"
      "completed" -> "#{base} bg-emerald-500/20 text-emerald-400 border border-emerald-500/30"
      "failed" -> "#{base} bg-red-500/20 text-red-400 border border-red-500/30"
      "draft" -> "#{base} bg-zinc-700/50 text-zinc-400 border border-zinc-700"
      "paused" -> "#{base} bg-zinc-700/50 text-zinc-400 border border-zinc-700"
      _ -> "#{base} bg-zinc-700/50 text-zinc-400 border border-zinc-700"
    end
  end
end
