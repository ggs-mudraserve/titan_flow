defmodule TitanFlowWeb.TemplatesLive do
  use TitanFlowWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, current_path: "/templates")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header title="Templates">
      <:actions>
        <.button variant={:primary} size={:sm}>+ Create Template</.button>
      </:actions>
    </.page_header>

    <div class="bg-zinc-900 rounded-lg border border-zinc-800">
      <div class="p-6 text-center">
        <span class="text-4xl text-zinc-700">📄</span>
        <p class="mt-4 text-zinc-400">No templates found.</p>
        <p class="mt-2 text-zinc-500 text-sm">Create your first WhatsApp message template.</p>
      </div>
    </div>
    """
  end
end
