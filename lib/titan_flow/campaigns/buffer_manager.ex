defmodule TitanFlow.Campaigns.BufferManager do
  @moduledoc """
  JIT (Just-In-Time) Buffer Manager for campaign message queues.
  
  Maintains a Redis buffer of max 20,000 messages per phone.
  Refills from Postgres when buffer drops below threshold.
  
  ## Strategy
  - Max buffer: 20,000 messages
  - Refill threshold: 5,000 messages
  - Batch size: 10,000 messages per refill
  - Check interval: 5 seconds
  """

  use GenServer
  require Logger
  import Ecto.Query

  alias TitanFlow.Repo
  alias TitanFlow.Campaigns

  # Configuration
  @max_buffer 20_000
  @refill_threshold 5_000
  @batch_size 10_000
  @check_interval_ms 5_000

  # Client API

  @doc """
  Start a BufferManager for a specific campaign and phone.
  """
  def start_link(opts) do
    campaign_id = Keyword.fetch!(opts, :campaign_id)
    phone_number_id = Keyword.fetch!(opts, :phone_number_id)
    
    name = via_tuple(campaign_id, phone_number_id)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Stop a BufferManager.
  """
  def stop(campaign_id, phone_number_id) do
    name = via_tuple(campaign_id, phone_number_id)
    case GenServer.whereis(name) do
      nil -> :ok
      pid -> GenServer.stop(pid, :normal)
    end
  end

  @doc """
  Get current buffer status.
  """
  def status(campaign_id, phone_number_id) do
    name = via_tuple(campaign_id, phone_number_id)
    case GenServer.whereis(name) do
      nil -> {:error, :not_running}
      pid -> GenServer.call(pid, :status)
    end
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    campaign_id = Keyword.fetch!(opts, :campaign_id)
    phone_number_id = Keyword.fetch!(opts, :phone_number_id)
    
    state = %{
      campaign_id: campaign_id,
      phone_number_id: phone_number_id,
      last_contact_id: 0,  # Cursor for pagination
      total_pushed: 0,
      is_exhausted: false,  # True when no more contacts to push
      phone_index: Keyword.get(opts, :phone_index, 0),
      total_phones: Keyword.get(opts, :total_phones, 1)
    }
    
    Logger.info("BufferManager started for campaign #{campaign_id}, phone #{phone_number_id}")
    
    # Initial fill
    send(self(), :check_buffer)
    
    {:ok, state}
  end

  @impl true
  def handle_info(:check_buffer, state) do
    if state.is_exhausted do
      # No more contacts, just keep checking for campaign completion
      schedule_check()
      {:noreply, state}
    else
      state = check_and_refill(state)
      schedule_check()
      {:noreply, state}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:ok, queue_size} = get_queue_size(state.phone_number_id, state.campaign_id)
    
    status = %{
      campaign_id: state.campaign_id,
      phone_number_id: state.phone_number_id,
      queue_size: queue_size,
      total_pushed: state.total_pushed,
      last_contact_id: state.last_contact_id,
      is_exhausted: state.is_exhausted
    }
    
    {:reply, {:ok, status}, state}
  end

  # Private Functions

  defp check_and_refill(state) do
    {:ok, queue_size} = get_queue_size(state.phone_number_id, state.campaign_id)
    
    cond do
      queue_size >= @refill_threshold ->
        # Buffer is healthy, no action needed
        state
        
      queue_size < @refill_threshold ->
        # Need to refill
        Logger.info("BufferManager: Queue at #{queue_size}, refilling for campaign #{state.campaign_id}")
        refill_buffer(state)
    end
  end

  defp refill_buffer(state) do
    # Calculate how many to fetch
    {:ok, current_size} = get_queue_size(state.phone_number_id, state.campaign_id)
    space_available = @max_buffer - current_size
    fetch_count = min(space_available, @batch_size)
    
    if fetch_count <= 0 do
      state
    else
      # Fetch contacts using cursor-based pagination with round-robin distribution
      contacts = fetch_unsent_contacts(
        state.campaign_id, 
        state.last_contact_id, 
        fetch_count,
        state.phone_index,
        state.total_phones
      )
      
      if Enum.empty?(contacts) do
        Logger.info("BufferManager: No more contacts for campaign #{state.campaign_id}, marking exhausted")
        
        # Trigger completion check asynchronously (don't block BufferManager)
        Task.start(fn ->
          # Small delay to ensure last messages are sent
          Process.sleep(5000)
          TitanFlow.Campaigns.MessageTracking.check_campaign_completion(state.campaign_id)
        end)
        
        %{state | is_exhausted: true}
      else
        # Push to Redis
        pushed = push_to_redis(contacts, state.phone_number_id, state.campaign_id)
        new_last_id = contacts |> List.last() |> Map.get(:id)
        
        Logger.info("BufferManager: Pushed #{pushed} contacts, cursor now at #{new_last_id}")
        
        %{state | 
          last_contact_id: new_last_id,
          total_pushed: state.total_pushed + pushed
        }
      end
    end
  end

  defp fetch_unsent_contacts(campaign_id, after_id, limit, phone_index, total_phones) do
    # Efficient cursor-based pagination
    # Only fetches contacts that have NEVER been sent (no message_log entry at all)
    # Failed contacts are NOT retried here - use "Retry Failed" button after campaign completes
    # Duplicate protection via unique meta_message_id constraint prevents double-sends
    query = from c in "contacts",
      left_join: m in "message_logs", 
        on: m.contact_id == c.id and m.campaign_id == c.campaign_id,
      where: c.campaign_id == ^campaign_id,
      where: c.id > ^after_id,
      where: c.is_blacklisted == false,
      # Only truly unsent contacts (no message_log entry)
      where: is_nil(m.id),
      order_by: [asc: c.id],
      limit: ^limit,
      select: %{
        id: c.id,
        phone: c.phone,
        name: c.name,
        variables: c.variables
      }
    
    Repo.all(query)
  end

  defp push_to_redis(contacts, phone_number_id, campaign_id) do
    queue_name = "queue:sending:#{campaign_id}:#{phone_number_id}"
    
    commands = Enum.map(contacts, fn contact ->
      payload = Jason.encode!(%{
        contact_id: contact.id,
        phone: contact.phone,
        name: contact.name,
        variables: contact.variables
      })
      ["RPUSH", queue_name, payload]
    end)
    
    case Redix.pipeline(:redix, commands) do
      {:ok, _results} -> length(contacts)
      {:error, reason} ->
        Logger.error("BufferManager: Failed to push to Redis: #{inspect(reason)}")
        0
    end
  end

  defp get_queue_size(phone_number_id, campaign_id) do
    queue_name = "queue:sending:#{campaign_id}:#{phone_number_id}"
    Redix.command(:redix, ["LLEN", queue_name])
  end

  defp schedule_check do
    Process.send_after(self(), :check_buffer, @check_interval_ms)
  end

  defp via_tuple(campaign_id, phone_number_id) do
    {:via, Registry, {TitanFlow.BufferRegistry, {campaign_id, phone_number_id}}}
  end
end
