defmodule TitanFlowWeb.InboxLive do
  use TitanFlowWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, current_path: "/inbox")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header title="Inbox" />

    <div class="bg-zinc-900 rounded-lg border border-zinc-800">
      <div class="p-6 text-center">
        <span class="text-4xl text-zinc-700">💬</span>
        <p class="mt-4 text-zinc-400">No messages in inbox.</p>
        <p class="mt-2 text-zinc-500 text-sm">Customer replies will appear here.</p>
      </div>
    </div>
    """
  end
end
