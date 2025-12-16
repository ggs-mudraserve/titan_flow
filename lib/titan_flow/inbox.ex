defmodule TitanFlow.Inbox do
  @moduledoc """
  Context for inbox operations with strict pagination for performance.
  """

  import Ecto.Query
  alias TitanFlow.Repo
  alias TitanFlow.Inbox.{Conversation, Message}

  # Pagination struct
  defmodule Page do
    defstruct [:entries, :page_number, :total_pages, :total_entries]
  end

  @doc """
  List conversations with pagination.
  Returns %Page{entries: [...], page_number: N, total_pages: T, total_entries: E}
  """
  def list_conversations(page \\ 1, per_page \\ 20) do
    offset = (page - 1) * per_page

    query = from c in Conversation,
      order_by: [desc: c.last_message_at],
      preload: [:phone_number]

    total_entries = Repo.aggregate(Conversation, :count)
    total_pages = max(1, ceil(total_entries / per_page))

    entries = 
      query
      |> limit(^per_page)
      |> offset(^offset)
      |> Repo.all()

    %Page{
      entries: entries,
      page_number: page,
      total_pages: total_pages,
      total_entries: total_entries
    }
  end

  @doc """
  List conversations filtered by search term.
  """
  def search_conversations(search_term, page \\ 1, per_page \\ 20) do
    offset = (page - 1) * per_page
    search_pattern = "%#{search_term}%"

    query = from c in Conversation,
      where: ilike(c.contact_name, ^search_pattern) or ilike(c.contact_phone, ^search_pattern),
      order_by: [desc: c.last_message_at],
      preload: [:phone_number]

    count_query = from c in Conversation,
      where: ilike(c.contact_name, ^search_pattern) or ilike(c.contact_phone, ^search_pattern)

    total_entries = Repo.aggregate(count_query, :count)
    total_pages = max(1, ceil(total_entries / per_page))

    entries = 
      query
      |> limit(^per_page)
      |> offset(^offset)
      |> Repo.all()

    %Page{
      entries: entries,
      page_number: page,
      total_pages: total_pages,
      total_entries: total_entries
    }
  end

  @doc """
  Get a conversation by ID.
  """
  def get_conversation!(id) do
    Repo.get!(Conversation, id) |> Repo.preload(:phone_number)
  end

  @doc """
  List messages for a conversation with offset-based pagination.
  Returns most recent messages first (for prepending older messages).
  """
  def list_messages(conversation_id, limit \\ 50, offset \\ 0) do
    # Get messages in reverse order (newest first) for pagination
    query = from m in Message,
      where: m.conversation_id == ^conversation_id,
      order_by: [desc: m.inserted_at],
      limit: ^limit,
      offset: ^offset

    messages = Repo.all(query)
    
    # Reverse to show oldest-first for display
    Enum.reverse(messages)
  end

  @doc """
  Get total message count for a conversation.
  """
  def count_messages(conversation_id) do
    Repo.aggregate(
      from(m in Message, where: m.conversation_id == ^conversation_id),
      :count
    )
  end

  @doc """
  Check if a message with the given meta_message_id already exists.
  Used to prevent duplicate message creation from webhook retries.
  """
  def message_exists?(meta_message_id) when is_binary(meta_message_id) do
    Repo.exists?(from m in Message, where: m.meta_message_id == ^meta_message_id)
  end
  def message_exists?(_), do: false

  @doc """
  Create a new message and update conversation.
  """
  def create_message(attrs) do
    Repo.transaction(fn ->
      changeset = Message.changeset(%Message{}, attrs)
      
      case Repo.insert(changeset) do
        {:ok, message} ->
          # Update conversation's last message
          conversation = Repo.get!(Conversation, message.conversation_id)
          preview = String.slice(message.content || "", 0, 50)
          
          updates = %{
            last_message_at: message.inserted_at,
            last_message_preview: preview
          }
          
          updates = if message.direction == "inbound" do
            Map.put(updates, :unread_count, conversation.unread_count + 1)
          else
            updates
          end
          
          Conversation.changeset(conversation, updates)
          |> Repo.update!()
          
          message
          
        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Update message status and meta ID.
  """
  def update_message_status(message_id, status, meta_message_id, error_message \\ nil) do
    message = Repo.get!(Message, message_id)
    
    updates = %{
      status: status,
      meta_message_id: meta_message_id,
      error_message: error_message
    }
    
    # Clean nil values
    updates = Enum.reject(updates, fn {_k, v} -> is_nil(v) end) |> Map.new()
    
    Message.changeset(message, updates)
    |> Repo.update()
  end

  @doc """
  Mark conversation as read (reset unread count).
  """
  def mark_as_read(conversation_id) do
    from(c in Conversation, where: c.id == ^conversation_id)
    |> Repo.update_all(set: [unread_count: 0])
  end

  @doc """
  Toggle AI pause for a conversation.
  """
  def toggle_ai_pause(conversation_id) do
    conversation = Repo.get!(Conversation, conversation_id)
    new_value = not conversation.is_ai_paused
    
    conversation
    |> Conversation.changeset(%{is_ai_paused: new_value})
    |> Repo.update()
  end

  @doc """
  Create or get conversation for a contact.
  """
  def get_or_create_conversation(contact_phone, phone_number_id, contact_name \\ nil) do
    case Repo.get_by(Conversation, contact_phone: contact_phone, phone_number_id: phone_number_id) do
      nil ->
        %Conversation{}
        |> Conversation.changeset(%{
          contact_phone: contact_phone,
          phone_number_id: phone_number_id,
          contact_name: contact_name
        })
        |> Repo.insert()
      conversation ->
        {:ok, conversation}
    end
  end

  @doc """
  Broadcast new message to PubSub.
  """
  def broadcast_new_message(message, conversation) do
    Phoenix.PubSub.broadcast(
      TitanFlow.PubSub,
      "inbox:new_message",
      {:new_message, message, conversation}
    )
  end

  # =============================================================
  # OPTIMIZED FUNCTIONS FOR HIGH-PERFORMANCE WEBHOOK PROCESSING
  # =============================================================

  @doc """
  Atomic upsert: Get or create conversation AND increment unread in one query.
  
  On conflict (existing conversation):
  - Increments unread_count by 1
  - Updates last_message_at to now
  
  Returns {:ok, conversation} with the inserted/updated record.
  """
  def upsert_conversation(contact_phone, phone_number_id, contact_name) do
    now = DateTime.utc_now()
    
    changeset = Conversation.changeset(%Conversation{}, %{
      contact_phone: contact_phone,
      phone_number_id: phone_number_id,
      contact_name: contact_name,
      last_message_at: now,
      unread_count: 1
    })

    # Postgres upsert: INSERT ... ON CONFLICT DO UPDATE
    Repo.insert(changeset,
      on_conflict: {:replace_all_except, [:id, :contact_phone, :phone_number_id, :contact_name, :inserted_at]},
      conflict_target: [:contact_phone, :phone_number_id],
      returning: true
    )
    |> case do
      {:ok, conv} ->
        # If it was an update (existing conversation), we need to increment unread_count
        # The replace_all_except resets to 1, so we do a separate increment
        if conv.inserted_at != conv.updated_at do
          # This was an update, increment the unread count properly
          from(c in Conversation, where: c.id == ^conv.id)
          |> Repo.update_all(inc: [unread_count: 1], set: [last_message_at: now])
          
          # Return fresh conversation
          {:ok, Repo.get!(Conversation, conv.id) |> Repo.preload(:phone_number)}
        else
          # New conversation, preload and return
          {:ok, Repo.preload(conv, :phone_number)}
        end
      error -> error
    end
  end

  @doc """
  Create message with deduplication via unique constraint.
  
  Returns:
  - {:ok, message} - Message was created successfully
  - {:duplicate, nil} - Message with this meta_message_id already exists  
  - {:error, changeset} - Validation or other error
  """
  def create_message_dedup(attrs) do
    changeset = Message.changeset(%Message{}, attrs)
    
    case Repo.insert(changeset, on_conflict: :nothing) do
      {:ok, %Message{id: nil}} -> 
        # Conflict - message with this meta_message_id already exists
        {:duplicate, nil}
      {:ok, message} -> 
        {:ok, message}
      {:error, changeset} -> 
        {:error, changeset}
    end
  end

  @doc """
  Update conversation preview efficiently (single UPDATE query).
  """
  def update_conversation_preview(conversation_id, content) do
    preview = String.slice(content || "", 0, 50)
    
    from(c in Conversation, where: c.id == ^conversation_id)
    |> Repo.update_all(set: [last_message_preview: preview])
  end
end
