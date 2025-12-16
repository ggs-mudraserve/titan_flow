defmodule TitanFlowWeb.SettingsLive do
  use TitanFlowWeb, :live_view

  alias TitanFlow.Settings

  @impl true
  def mount(_params, _session, socket) do
    api_key = Settings.get_value("openai_api_key", "")
    
    {:ok, assign(socket, 
      api_key: api_key,
      current_path: "/settings",
      saved: false
    )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header title="Settings" />

    <div class="max-w-xl">
      <div class="bg-zinc-900 rounded-lg border border-zinc-800 p-5">
        <h3 class="text-sm font-medium text-zinc-400 uppercase tracking-wider mb-4">AI Configuration</h3>
        
        <form phx-submit="save" class="space-y-4">
          <div>
            <label class="block text-sm font-medium text-zinc-300 mb-2">
              OpenAI API Key
            </label>
            <input 
              type="password" 
              name="openai_api_key" 
              value={@api_key} 
              placeholder="sk-..." 
              class="w-full h-9 px-3 rounded-md text-sm bg-zinc-900 border border-zinc-800 text-zinc-100 placeholder-zinc-500 hover:border-zinc-700 focus:outline-none focus:ring-1 focus:ring-indigo-500/50 focus:border-indigo-500"
            />
            <p class="mt-2 text-xs text-zinc-500">
              This key will be used for AI auto-replies across all phone numbers.
            </p>
          </div>

          <div class="flex items-center justify-between pt-4 border-t border-zinc-800">
            <button 
              type="submit" 
              class="h-8 px-3 rounded text-sm font-medium bg-indigo-600 hover:bg-indigo-500 text-white transition-colors"
            >
              Save Settings
            </button>
            
            <%= if @saved do %>
              <span class="text-sm text-emerald-400 font-medium">
                ✓ Settings saved
              </span>
            <% end %>
          </div>
        </form>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("save", %{"openai_api_key" => key}, socket) do
    Settings.set_value("openai_api_key", key)
    
    {:noreply, assign(socket, 
      api_key: key, 
      saved: true
    )}
  end
end
