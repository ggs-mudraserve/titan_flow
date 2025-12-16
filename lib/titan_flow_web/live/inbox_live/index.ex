defmodule TitanFlowWeb.InboxLive.Index do
  use TitanFlowWeb, :live_view

  alias TitanFlow.Inbox
  alias TitanFlow.Inbox.{Conversation, Message}
  alias TitanFlow.Templates

  @conversations_per_page 20
  @messages_per_load 50

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(TitanFlow.PubSub, "inbox:new_message")
    end

    # Load first page of conversations
    page = Inbox.list_conversations(1, @conversations_per_page)

    socket =
      socket
      |> assign(current_path: "/inbox")
      |> assign(page_title: "Inbox")
      |> assign(conversations_page: 1)
      |> assign(conversations_total_pages: page.total_pages)
      |> assign(search_term: "")
      |> assign(active_conversation: nil)
      |> assign(messages_offset: 0)
      |> assign(has_more_messages: false)
      |> assign(loading_more: false)
      |> assign(message_input: "")
      |> assign(show_template_picker: false)
      |> assign(templates: [])
      |> stream(:conversations, page.entries)
      |> stream(:messages, [])

    {:ok, socket}
  end

  # Event Handlers

  @impl true
  def handle_event("search", %{"term" => term}, socket) do
    socket = assign(socket, search_term: term, conversations_page: 1)
    
    page = if term == "" do
      Inbox.list_conversations(1, @conversations_per_page)
    else
      Inbox.search_conversations(term, 1, @conversations_per_page)
    end
    
    socket =
      socket
      |> assign(conversations_total_pages: page.total_pages)
      |> stream(:conversations, page.entries, reset: true)
    
    {:noreply, socket}
  end

  @impl true
  def handle_event("load_more_conversations", _params, socket) do
    current_page = socket.assigns.conversations_page
    total_pages = socket.assigns.conversations_total_pages
    
    if current_page < total_pages do
      next_page = current_page + 1
      
      page = if socket.assigns.search_term == "" do
        Inbox.list_conversations(next_page, @conversations_per_page)
      else
        Inbox.search_conversations(socket.assigns.search_term, next_page, @conversations_per_page)
      end
      
      socket =
        socket
        |> assign(conversations_page: next_page)
        |> stream(:conversations, page.entries)
      
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("select_conversation", %{"id" => id}, socket) do
    conversation = Inbox.get_conversation!(id)
    
    # Mark as read
    Inbox.mark_as_read(conversation.id)
    
    # Load last 50 messages
    messages = Inbox.list_messages(conversation.id, @messages_per_load, 0)
    total_count = Inbox.count_messages(conversation.id)
    has_more = length(messages) < total_count
    
    # Load templates for picker
    templates = Templates.list_templates()
    
    socket =
      socket
      |> assign(active_conversation: conversation)
      |> assign(messages_offset: length(messages))
      |> assign(has_more_messages: has_more)
      |> assign(templates: templates)
      |> stream(:messages, messages, reset: true)
      # Update the conversation in sidebar to reset unread count
      |> stream_insert(:conversations, %{conversation | unread_count: 0})
    
    {:noreply, socket}
  end

  @impl true
  def handle_event("load_older", _params, socket) do
    conversation = socket.assigns.active_conversation
    offset = socket.assigns.messages_offset
    
    socket = assign(socket, loading_more: true)
    
    messages = Inbox.list_messages(conversation.id, @messages_per_load, offset)
    
    if Enum.empty?(messages) do
      {:noreply, assign(socket, has_more_messages: false, loading_more: false)}
    else
      # Prepend older messages at the start
      socket =
        socket
        |> assign(messages_offset: offset + length(messages))
        |> assign(loading_more: false)
        |> assign(has_more_messages: length(messages) == @messages_per_load)
      
      # Insert at position 0 (prepend)
      socket = Enum.reduce(messages, socket, fn msg, acc ->
        stream_insert(acc, :messages, msg, at: 0)
      end)
      
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("update_input", %{"value" => value}, socket) do
    {:noreply, assign(socket, message_input: value)}
  end

  @impl true
  @impl true
  def handle_event("send_message", _params, socket) do
    conversation = socket.assigns.active_conversation
    content = socket.assigns.message_input
    
    if conversation && content != "" do
      # 1. Create local message first
      {:ok, message} = Inbox.create_message(%{
        conversation_id: conversation.id,
        direction: "outbound",
        content: content,
        status: "pending"
      })
      
      socket =
        socket
        |> assign(message_input: "")
        |> stream_insert(:messages, message)
      
      # 2. Spawn task to send via WhatsApp API
      # Using Task.start to verify it works without blocking UI, 
      # but ideally we should handle result to update UI
      # We'll do it synchronously here for feedback for now since it's a live chat
      
      phone = conversation.phone_number
      
      send_result = TitanFlow.WhatsApp.Client.send_text(
        phone.phone_number_id,
        conversation.contact_phone,
        content,
        phone.access_token
      )
      
      case send_result do
        {:ok, response} ->
          # Extract message ID
          meta_id = get_in(response, ["messages", Access.at(0), "id"])
          
          # Update message status
          {:ok, updated_message} = Inbox.update_message_status(message.id, "sent", meta_id)
          
          {:noreply, stream_insert(socket, :messages, updated_message)}
          
        {:error, reason} ->
          # Update to failed
          {:ok, failed_message} = Inbox.update_message_status(message.id, "failed", nil, inspect(reason))
          
          {:noreply, 
            socket 
            |> put_flash(:error, "Failed to send message")
            |> stream_insert(:messages, failed_message)}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_ai", _params, socket) do
    conversation = socket.assigns.active_conversation
    
    if conversation do
      {:ok, updated} = Inbox.toggle_ai_pause(conversation.id)
      socket =
        socket
        |> assign(active_conversation: updated)
        |> stream_insert(:conversations, updated)
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_template_picker", _params, socket) do
    {:noreply, assign(socket, show_template_picker: not socket.assigns.show_template_picker)}
  end

  @impl true
  def handle_event("select_template", %{"name" => name}, socket) do
    {:noreply, socket
      |> assign(message_input: "[Template: #{name}]")
      |> assign(show_template_picker: false)}
  end

  # PubSub Handler

  @impl true
  def handle_info({:new_message, message, conversation}, socket) do
    active = socket.assigns.active_conversation
    
    socket = if active && active.id == conversation.id do
      # Message for active chat - add to stream
      stream_insert(socket, :messages, message)
    else
      # Message for different chat - update sidebar
      # Increment unread and move to top
      updated_conv = %{conversation | unread_count: conversation.unread_count + 1}
      socket
      |> stream_delete(:conversations, conversation)
      |> stream_insert(:conversations, updated_conv, at: 0)
    end
    
    {:noreply, socket}
  end

  # Helpers

  defp format_time(nil), do: ""
  defp format_time(datetime) do
    Calendar.strftime(datetime, "%H:%M")
  end

  defp format_date(nil), do: ""
  defp format_date(datetime) do
    Calendar.strftime(datetime, "%b %d")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-[calc(100vh-6rem)] -m-6 bg-zinc-950">
      <!-- Sidebar: Conversations List -->
      <div class="w-80 bg-zinc-900 border-r border-zinc-800 flex flex-col">
        <!-- Search -->
        <div class="p-3 border-b border-zinc-800">
          <form phx-change="search" phx-submit="search">
            <input
              type="text"
              name="term"
              placeholder="Search contacts..."
              value={@search_term}
              phx-debounce="300"
              class="w-full h-9 px-3 rounded-md text-sm bg-zinc-800 border border-zinc-700 text-zinc-100 placeholder-zinc-500 focus:outline-none focus:border-indigo-500"
            />
          </form>
        </div>

        <!-- Conversations -->
        <div
          id="conversations-list"
          class="flex-1 overflow-y-auto"
          phx-hook="InfiniteScroll"
          data-event="load_more_conversations"
        >
          <div id="conversations" phx-update="stream">
            <%= for {dom_id, conversation} <- @streams.conversations do %>
              <div
                id={dom_id}
                phx-click="select_conversation"
                phx-value-id={conversation.id}
                class={[
                  "p-3 border-b border-zinc-800/50 cursor-pointer transition-colors",
                  @active_conversation && @active_conversation.id == conversation.id && "bg-zinc-800",
                  !(@active_conversation && @active_conversation.id == conversation.id) && "hover:bg-zinc-800/50"
                ]}
              >
                <div class="flex items-start gap-3">
                  <div class="w-9 h-9 rounded-full bg-indigo-600 flex items-center justify-center text-white font-medium text-sm">
                    <%= String.first(conversation.contact_name || conversation.contact_phone || "?") %>
                  </div>
                  <div class="flex-1 min-w-0">
                    <div class="flex items-center justify-between">
                      <p class="text-zinc-100 font-medium text-sm truncate">
                        <%= conversation.contact_name || conversation.contact_phone %>
                      </p>
                      <span class="text-xs text-zinc-500 font-mono"><%= format_time(conversation.last_message_at) %></span>
                    </div>
                    <div class="flex items-center justify-between mt-0.5">
                      <p class="text-zinc-500 text-xs truncate">
                        <%= conversation.last_message_preview || "No messages yet" %>
                      </p>
                      <%= if conversation.unread_count > 0 do %>
                        <span class="ml-2 px-1.5 py-0.5 bg-indigo-600 rounded-full text-xs text-white font-medium">
                          <%= conversation.unread_count %>
                        </span>
                      <% end %>
                    </div>
                  </div>
                </div>
              </div>
            <% end %>
          </div>
          
          <!-- Load more trigger -->
          <%= if @conversations_page < @conversations_total_pages do %>
            <div class="p-3 text-center text-zinc-600 text-xs">
              Loading more...
            </div>
          <% end %>
        </div>
      </div>

      <!-- Main: Chat Window -->
      <div class="flex-1 flex flex-col bg-zinc-950">
        <%= if @active_conversation do %>
          <!-- Chat Header -->
          <div class="h-14 px-4 border-b border-zinc-800 flex items-center justify-between bg-zinc-900">
            <div class="flex items-center gap-3">
              <div class="w-9 h-9 rounded-full bg-indigo-600 flex items-center justify-center text-white font-medium text-sm">
                <%= String.first(@active_conversation.contact_name || @active_conversation.contact_phone || "?") %>
              </div>
              <div>
                <p class="text-zinc-100 font-medium text-sm">
                  <%= @active_conversation.contact_name || @active_conversation.contact_phone %>
                </p>
                <p class="text-zinc-500 text-xs font-mono"><%= @active_conversation.contact_phone %></p>
              </div>
            </div>
            <div class="flex items-center gap-2">
              <button
                phx-click="toggle_ai"
                class={[
                  "h-7 px-2.5 rounded text-xs font-medium transition-colors",
                  @active_conversation.is_ai_paused && "bg-amber-500/20 text-amber-400 border border-amber-500/30",
                  !@active_conversation.is_ai_paused && "bg-emerald-500/20 text-emerald-400 border border-emerald-500/30"
                ]}
              >
                <%= if @active_conversation.is_ai_paused, do: "🤖 AI Paused", else: "🤖 AI Active" %>
              </button>
            </div>
          </div>

          <!-- Messages Area -->
          <div id="messages-container" class="flex-1 overflow-y-auto p-4 space-y-3">
            <!-- Load older button -->
            <%= if @has_more_messages do %>
              <div class="text-center">
                <button
                  phx-click="load_older"
                  disabled={@loading_more}
                  class="h-7 px-3 bg-zinc-800 text-zinc-400 rounded text-xs font-medium hover:bg-zinc-700 transition-colors disabled:opacity-50"
                >
                  <%= if @loading_more, do: "Loading...", else: "↑ Load older messages" %>
                </button>
              </div>
            <% end %>

            <div id="messages" phx-update="stream">
              <%= for {dom_id, message} <- @streams.messages do %>
                <div
                  id={dom_id}
                  class={[
                    "flex",
                    message.direction == "outbound" && "justify-end",
                    message.direction == "inbound" && "justify-start"
                  ]}
                >
                  <div class={[
                    "max-w-md px-3 py-2 rounded-xl text-sm",
                    message.direction == "outbound" && "bg-indigo-600 text-white",
                    message.direction == "inbound" && "bg-zinc-800 text-zinc-100"
                  ]}>
                    <p class="whitespace-pre-wrap"><%= message.content %></p>
                    <div class="flex items-center justify-end gap-1.5 mt-1">
                      <%= if message.is_ai_generated do %>
                        <span class="text-xs opacity-60">🤖</span>
                      <% end %>
                      <span class="text-xs opacity-60 font-mono"><%= format_time(message.inserted_at) %></span>
                      <%= if message.direction == "outbound" do %>
                        <span class="text-xs opacity-60">
                          <%= case message.status do %>
                            <% "delivered" -> %>✓✓
                            <% "read" -> %>✓✓
                            <% "sent" -> %>✓
                            <% _ -> %>⏳
                          <% end %>
                        </span>
                      <% end %>
                    </div>
                  </div>
                </div>
              <% end %>
            </div>
          </div>

          <!-- Input Area -->
          <div class="p-3 border-t border-zinc-800 bg-zinc-900">
            <!-- Template Picker -->
            <%= if @show_template_picker do %>
              <div class="mb-3 p-3 bg-zinc-800 rounded-lg max-h-40 overflow-y-auto border border-zinc-700">
                <p class="text-zinc-500 text-xs mb-2">Select a template:</p>
                <div class="space-y-0.5">
                  <%= for template <- @templates do %>
                    <button
                      phx-click="select_template"
                      phx-value-name={template.name}
                      class="w-full text-left px-2 py-1.5 rounded text-sm text-zinc-300 hover:bg-zinc-700 transition-colors"
                    >
                      📄 <%= template.name %>
                    </button>
                  <% end %>
                  <%= if Enum.empty?(@templates) do %>
                    <p class="text-zinc-600 text-xs">No templates available</p>
                  <% end %>
                </div>
              </div>
            <% end %>

            <div class="flex items-end gap-2">
              <button
                phx-click="toggle_template_picker"
                class="h-9 w-9 bg-zinc-800 text-zinc-400 rounded-lg hover:bg-zinc-700 transition-colors flex items-center justify-center"
              >
                📄
              </button>
              <div class="flex-1">
                <textarea
                  id="message-input"
                  rows="1"
                  placeholder="Type a message..."
                  value={@message_input}
                  phx-keyup="update_input"
                  phx-value-value={@message_input}
                  class="w-full h-9 px-3 py-2 rounded-lg text-sm bg-zinc-800 border border-zinc-700 text-zinc-100 placeholder-zinc-500 focus:outline-none focus:border-indigo-500 resize-none"
                  phx-hook="AutoResize"
                ><%= @message_input %></textarea>
              </div>
              <button
                phx-click="send_message"
                class="h-9 w-9 bg-indigo-600 text-white rounded-lg hover:bg-indigo-500 transition-colors flex items-center justify-center"
              >
                ➤
              </button>
            </div>
          </div>
        <% else %>
          <!-- Empty State -->
          <div class="flex-1 flex items-center justify-center">
            <div class="text-center">
              <span class="text-5xl text-zinc-700">💬</span>
              <p class="mt-4 text-zinc-400 text-sm">Select a conversation</p>
              <p class="text-zinc-600 text-xs">Choose from your contacts on the left</p>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
