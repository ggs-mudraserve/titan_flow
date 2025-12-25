defmodule TitanFlowWeb.DashboardLive.Index do
  use TitanFlowWeb, :live_view

  alias TitanFlow.Stats

  # 30 seconds
  @refresh_interval 30_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      schedule_refresh()
    end

    socket =
      socket
      |> assign(current_path: "/dashboard")
      |> assign(page_title: "Dashboard")
      |> assign_stats()

    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh, socket) do
    schedule_refresh()
    {:noreply, assign_stats(socket)}
  end

  defp schedule_refresh do
    Process.send_after(self(), :refresh, @refresh_interval)
  end

  defp assign_stats(socket) do
    daily_activity = Stats.get_daily_activity(7)
    monthly_summary = Stats.get_monthly_summary()
    global_stats = Stats.get_global_stats()
    month_label = Stats.get_current_month_label()

    socket
    |> assign(:daily_activity, daily_activity)
    |> assign(:monthly_summary, monthly_summary)
    |> assign(:global_stats, global_stats)
    |> assign(:month_label, month_label)
    |> assign(:bar_chart, build_bar_chart(daily_activity))
  end

  defp build_bar_chart(daily_activity) do
    max_val =
      daily_activity
      |> Enum.map(& &1.total)
      |> Enum.max()
      |> max(1)

    Enum.map(daily_activity, fn day ->
      height_pct = day.total / max_val * 100

      %{
        day_name: day.day_name,
        day_number: day.day_number,
        total: day.total,
        height_pct: height_pct,
        is_today: day.is_today
      }
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <!-- Daily Activity Section -->
      <div class="bg-base-100 rounded-2xl border border-base-200 shadow-sm overflow-hidden">
        <!-- Header -->
        <div class="flex items-center justify-between px-6 py-4 border-b border-base-200">
          <div class="flex items-center gap-3">
            <span class="text-xl">📅</span>
            <div>
              <h2 class="text-lg font-semibold text-base-content">Daily Activity</h2>
              <p class="text-xs text-base-content/50"><%= @month_label %></p>
            </div>
          </div>
          <div class="flex items-center gap-4 text-xs">
            <div class="flex items-center gap-1.5">
              <span class="w-2 h-2 rounded-full bg-green-500"></span>
              <span class="text-base-content/60">Sent</span>
            </div>
            <div class="flex items-center gap-1.5">
              <span class="w-2 h-2 rounded-full bg-teal-500"></span>
              <span class="text-base-content/60">Delivered</span>
            </div>
            <div class="flex items-center gap-1.5">
              <span class="w-2 h-2 rounded-full bg-orange-500"></span>
              <span class="text-base-content/60">Read</span>
            </div>
            <div class="flex items-center gap-1.5">
              <span class="w-2 h-2 rounded-full bg-red-500"></span>
              <span class="text-base-content/60">Failed</span>
            </div>
          </div>
        </div>

        <!-- Table -->
        <div class="overflow-x-auto">
          <table class="w-full">
            <thead>
              <tr class="text-xs text-base-content/50 uppercase tracking-wide">
                <th class="px-6 py-3 text-left font-medium">Day</th>
                <th class="px-6 py-3 text-right font-medium">Total</th>
                <th class="px-6 py-3 text-right font-medium">Sent</th>
                <th class="px-6 py-3 text-right font-medium">Delivered</th>
                <th class="px-6 py-3 text-right font-medium">Read</th>
                <th class="px-6 py-3 text-right font-medium">Failed</th>
                <th class="px-6 py-3 text-right font-medium">Success %</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-base-200">
              <%= for day <- @daily_activity do %>
                <tr class={if day.is_today, do: "bg-primary/5", else: ""}>
                  <td class="px-6 py-4">
                    <div class="flex items-center gap-3">
                      <div class={[
                        "w-9 h-9 rounded-full flex items-center justify-center text-sm font-bold",
                        if(day.is_today, do: "bg-primary text-primary-content", else: "bg-base-200 text-base-content")
                      ]}>
                        <%= day.day_number %>
                      </div>
                      <div>
                        <span class="font-medium text-base-content"><%= day.day_name %></span>
                        <%= if day.is_today do %>
                          <span class="ml-2 text-xs text-primary font-medium">● Today</span>
                        <% end %>
                      </div>
                    </div>
                  </td>
                  <td class="px-6 py-4 text-right">
                    <span class="font-bold text-base-content"><%= Stats.format_indian(day.total) %></span>
                  </td>
                  <td class="px-6 py-4 text-right">
                    <span class="font-medium text-green-600"><%= Stats.format_indian(day.sent) %></span>
                  </td>
                  <td class="px-6 py-4 text-right">
                    <span class="font-medium text-teal-600"><%= Stats.format_indian(day.delivered) %></span>
                  </td>
                  <td class="px-6 py-4 text-right">
                    <span class="font-medium text-orange-600"><%= Stats.format_indian(day.read) %></span>
                  </td>
                  <td class="px-6 py-4 text-right">
                    <span class="font-medium text-red-600"><%= Stats.format_indian(day.failed) %></span>
                  </td>
                  <td class="px-6 py-4 text-right">
                    <span class={[
                      "font-bold",
                      cond do
                        day.success_pct >= 90 -> "text-green-600"
                        day.success_pct >= 80 -> "text-yellow-600"
                        true -> "text-red-600"
                      end
                    ]}><%= day.success_pct %>%</span>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>

        <!-- Summary Row -->
        <div class="grid grid-cols-5 border-t border-base-200">
          <div class="px-6 py-4 text-center border-r border-base-200">
            <p class="text-2xl font-bold text-base-content"><%= @monthly_summary.active_days %></p>
            <p class="text-xs text-base-content/50 mt-1">Active Days</p>
          </div>
          <div class="px-6 py-4 text-center border-r border-base-200 bg-green-50">
            <p class="text-2xl font-bold text-green-600"><%= Stats.format_indian(@monthly_summary.avg_per_day) %></p>
            <p class="text-xs text-green-600/70 mt-1">Avg/Day</p>
          </div>
          <div class="px-6 py-4 text-center border-r border-base-200 bg-teal-50">
            <p class="text-2xl font-bold text-teal-600"><%= Stats.format_indian(@monthly_summary.peak_day) %></p>
            <p class="text-xs text-teal-600/70 mt-1">Peak Day</p>
          </div>
          <div class="px-6 py-4 text-center border-r border-base-200 bg-orange-50">
            <p class="text-2xl font-bold text-orange-600"><%= Stats.format_indian(@monthly_summary.total_read) %></p>
            <p class="text-xs text-orange-600/70 mt-1">Total Read</p>
          </div>
          <div class="px-6 py-4 text-center bg-red-50">
            <p class="text-2xl font-bold text-red-600"><%= Stats.format_indian(@monthly_summary.total_failed) %></p>
            <p class="text-xs text-red-600/70 mt-1">Total Failed</p>
          </div>
        </div>
      </div>

      <!-- Daily Sends Bar Chart -->
      <div class="bg-base-100 rounded-2xl border border-base-200 shadow-sm p-6">
        <div class="flex items-center justify-between mb-6">
          <div class="flex items-center gap-3">
            <span class="text-xl">📊</span>
            <h2 class="text-lg font-semibold text-base-content">Daily Sends Trend</h2>
          </div>
          <p class="text-sm text-base-content/50">Last 7 days</p>
        </div>
        
        <div class="h-48 flex items-end justify-around gap-2">
          <%= for bar <- @bar_chart do %>
            <div class="flex-1 flex flex-col items-center">
              <div 
                class={[
                  "w-full rounded-t-lg transition-all",
                  if(bar.is_today, do: "bg-primary", else: "bg-primary/50")
                ]}
                style={"height: #{max(bar.height_pct, 2)}%; min-height: 4px;"}
                title={"#{bar.total} messages"}
              ></div>
              <div class="mt-2 text-center">
                <p class={["text-xs font-medium", if(bar.is_today, do: "text-primary", else: "text-base-content/60")]}><%= bar.day_name %></p>
                <p class={["text-[10px]", if(bar.is_today, do: "text-primary/70", else: "text-base-content/40")]}><%= bar.day_number %></p>
              </div>
            </div>
          <% end %>
        </div>
      </div>

      <!-- Bottom Stats Cards -->
      <div class="grid grid-cols-2 md:grid-cols-3 lg:grid-cols-6 gap-4">
        <!-- Messages -->
        <div class="bg-base-100 rounded-xl p-5 border border-base-200 shadow-sm">
          <div class="w-10 h-10 rounded-lg bg-blue-100 flex items-center justify-center mb-3">
            <span class="text-xl">💬</span>
          </div>
          <p class="text-xs text-base-content/50 font-medium">Messages</p>
          <p class="text-xl font-bold text-base-content mt-1"><%= Stats.format_indian(@global_stats.total_messages) %></p>
        </div>

        <!-- Contacts -->
        <div class="bg-base-100 rounded-xl p-5 border border-base-200 shadow-sm">
          <div class="w-10 h-10 rounded-lg bg-purple-100 flex items-center justify-center mb-3">
            <span class="text-xl">👥</span>
          </div>
          <p class="text-xs text-base-content/50 font-medium">Contacts</p>
          <p class="text-xl font-bold text-base-content mt-1"><%= Stats.format_indian(@global_stats.contacts_count) %></p>
        </div>

        <!-- Campaigns -->
        <div class="bg-base-100 rounded-xl p-5 border border-base-200 shadow-sm">
          <div class="w-10 h-10 rounded-lg bg-red-100 flex items-center justify-center mb-3">
            <span class="text-xl">📢</span>
          </div>
          <p class="text-xs text-base-content/50 font-medium">Campaigns</p>
          <p class="text-xl font-bold text-base-content mt-1"><%= @global_stats.campaigns_count %></p>
        </div>

        <!-- Templates -->
        <div class="bg-base-100 rounded-xl p-5 border border-base-200 shadow-sm">
          <div class="w-10 h-10 rounded-lg bg-orange-100 flex items-center justify-center mb-3">
            <span class="text-xl">📄</span>
          </div>
          <p class="text-xs text-base-content/50 font-medium">Templates</p>
          <p class="text-xl font-bold text-base-content mt-1"><%= @global_stats.templates_count %></p>
        </div>

        <!-- Numbers -->
        <div class="bg-base-100 rounded-xl p-5 border border-base-200 shadow-sm">
          <div class="w-10 h-10 rounded-lg bg-indigo-100 flex items-center justify-center mb-3">
            <span class="text-xl">📞</span>
          </div>
          <p class="text-xs text-base-content/50 font-medium">Numbers</p>
          <p class="text-xl font-bold text-base-content mt-1"><%= @global_stats.numbers_count %></p>
        </div>

        <!-- Success -->
        <div class="bg-base-100 rounded-xl p-5 border border-base-200 shadow-sm">
          <div class="w-10 h-10 rounded-lg bg-green-100 flex items-center justify-center mb-3">
            <span class="text-xl">✅</span>
          </div>
          <p class="text-xs text-base-content/50 font-medium">Success</p>
          <p class="text-xl font-bold text-green-600 mt-1"><%= @global_stats.success_pct %>%</p>
        </div>
      </div>
    </div>
    """
  end
end
