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
      # Cursor for pagination
      last_contact_id: 0,
      last_failed_id: 0,
      last_nolog_id: 0,
      total_pushed: 0,
      # True when no more contacts to push
      is_exhausted: false,
      # Weighted distribution: multiple indices for higher MPS phones
      weighted_indices: Keyword.get(opts, :weighted_indices, [0]),
      total_slots: Keyword.get(opts, :total_slots, 1),
      # True when retrying failed contacts
      retry_mode: Keyword.get(opts, :retry_mode, false)
    }

    Logger.info("BufferManager started for campaign #{campaign_id}, phone #{phone_number_id}")

    if state.retry_mode do
      retry_key = "campaign:#{campaign_id}:retry:bm_started"
      _ = Redix.command(:redix, ["SADD", retry_key, to_string(phone_number_id)])
      _ = Redix.command(:redix, ["EXPIRE", retry_key, 86_400])
    end

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
        Logger.info(
          "BufferManager: Queue at #{queue_size}, refilling for campaign #{state.campaign_id}"
        )

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
      {contacts, state} =
        if state.retry_mode do
          fetch_retry_contacts(state, fetch_count)
        else
          contacts =
            fetch_unsent_contacts(
              state.campaign_id,
              state.last_contact_id,
              fetch_count,
              state.weighted_indices,
              state.total_slots,
              state.retry_mode
            )

          {contacts, state}
        end

      if Enum.empty?(contacts) do
        Logger.info(
          "BufferManager: No more contacts for campaign #{state.campaign_id}, marking exhausted"
        )

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
        if state.retry_mode do
          Logger.info(
            "BufferManager: Pushed #{pushed} contacts (retry) failed_cursor=#{state.last_failed_id} nolog_cursor=#{state.last_nolog_id}"
          )

          %{state | total_pushed: state.total_pushed + pushed}
        else
          new_last_id = contacts |> List.last() |> Map.get(:id)

          Logger.info("BufferManager: Pushed #{pushed} contacts, cursor now at #{new_last_id}")

          %{state | last_contact_id: new_last_id, total_pushed: state.total_pushed + pushed}
        end
      end
    end
  end

  # Normal mode: Only fetch contacts that were NEVER ATTEMPTED
  # Uses weighted distribution - each phone has multiple indices based on MPS
  defp fetch_unsent_contacts(
         campaign_id,
         after_id,
         limit,
         weighted_indices,
         total_slots,
         false = _retry_mode
       ) do
    query =
      from c in "contacts",
        left_join: m in "message_logs",
        on: m.contact_id == c.id and m.campaign_id == c.campaign_id,
        where: c.campaign_id == ^campaign_id,
        where: c.id > ^after_id,
        where: c.is_blacklisted == false,
        # Only contacts with NO message_log
        where: is_nil(m.id),
        # WEIGHTED MODULO: Contact assigned to this phone if rem(id, total) IN indices
        where: fragment("? % ? = ANY(?)", c.id, ^total_slots, ^weighted_indices),
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

  defp fetch_retry_contacts(state, limit) do
    failed_limit = div(limit, 2)
    nolog_limit = limit - failed_limit

    failed_contacts =
      fetch_retry_failed_contacts(
        state.campaign_id,
        state.last_failed_id,
        failed_limit,
        state.weighted_indices,
        state.total_slots
      )

    nolog_contacts =
      fetch_retry_nolog_contacts(
        state.campaign_id,
        state.last_nolog_id,
        nolog_limit,
        state.weighted_indices,
        state.total_slots
      )

    new_last_failed_id = last_contact_id_or(state.last_failed_id, failed_contacts)
    new_last_nolog_id = last_contact_id_or(state.last_nolog_id, nolog_contacts)

    contacts = interleave_contacts(failed_contacts, nolog_contacts)
    remaining = limit - length(contacts)

    {contacts, new_last_failed_id, new_last_nolog_id} =
      cond do
        remaining > 0 and length(failed_contacts) < failed_limit ->
          extra =
            fetch_retry_nolog_contacts(
              state.campaign_id,
              new_last_nolog_id,
              remaining,
              state.weighted_indices,
              state.total_slots
            )

          new_last_nolog_id = last_contact_id_or(new_last_nolog_id, extra)
          {contacts ++ extra, new_last_failed_id, new_last_nolog_id}

        remaining > 0 and length(nolog_contacts) < nolog_limit ->
          extra =
            fetch_retry_failed_contacts(
              state.campaign_id,
              new_last_failed_id,
              remaining,
              state.weighted_indices,
              state.total_slots
            )

          new_last_failed_id = last_contact_id_or(new_last_failed_id, extra)
          {contacts ++ extra, new_last_failed_id, new_last_nolog_id}

        true ->
          {contacts, new_last_failed_id, new_last_nolog_id}
      end

    {contacts,
     %{
       state
       | last_failed_id: new_last_failed_id,
         last_nolog_id: new_last_nolog_id
     }}
  end

  defp fetch_retry_failed_contacts(campaign_id, after_id, limit, weighted_indices, total_slots)
       when limit > 0 do
    sql = """
    SELECT c.id, c.phone, c.name, c.variables
    FROM contacts c
    WHERE c.campaign_id = $1
      AND c.id > $2
      AND c.is_blacklisted = false
      AND c.id % $3 = ANY($4::int[])
      -- Exclude contacts with any successful send
      AND NOT EXISTS (
        SELECT 1 FROM message_logs m
        WHERE m.contact_id = c.id
          AND m.campaign_id = c.campaign_id
          AND m.status IN ('sent', 'delivered', 'read')
      )
      -- Include only contacts whose latest log is a retryable failure
      AND EXISTS (
        SELECT 1 FROM message_logs m
        WHERE m.contact_id = c.id
          AND m.campaign_id = c.campaign_id
          AND m.status = 'failed'
          AND (m.error_code IN ('131042', '131048', '130429', 'PHONE_EXHAUSTED') OR m.error_code LIKE '132%')
          AND m.inserted_at = (
            SELECT MAX(m2.inserted_at) FROM message_logs m2
            WHERE m2.contact_id = c.id AND m2.campaign_id = c.campaign_id
          )
      )
    ORDER BY c.id ASC
    LIMIT $5
    """

    run_retry_query(sql, [campaign_id, after_id, total_slots, weighted_indices, limit])
  end

  defp fetch_retry_failed_contacts(_campaign_id, _after_id, 0, _weighted_indices, _total_slots),
    do: []

  defp fetch_retry_nolog_contacts(campaign_id, after_id, limit, weighted_indices, total_slots)
       when limit > 0 do
    sql = """
    SELECT c.id, c.phone, c.name, c.variables
    FROM contacts c
    WHERE c.campaign_id = $1
      AND c.id > $2
      AND c.is_blacklisted = false
      AND c.id % $3 = ANY($4::int[])
      -- Include only contacts with no logs at all
      AND NOT EXISTS (
        SELECT 1 FROM message_logs m WHERE m.contact_id = c.id AND m.campaign_id = c.campaign_id
      )
    ORDER BY c.id ASC
    LIMIT $5
    """

    run_retry_query(sql, [campaign_id, after_id, total_slots, weighted_indices, limit])
  end

  defp fetch_retry_nolog_contacts(_campaign_id, _after_id, 0, _weighted_indices, _total_slots),
    do: []

  defp run_retry_query(sql, params) do
    case Repo.query(sql, params) do
      {:ok, %{rows: rows, columns: columns}} ->
        Enum.map(rows, fn row ->
          columns
          |> Enum.zip(row)
          |> Enum.into(%{}, fn {col, val} -> {String.to_atom(col), val} end)
        end)

      {:error, reason} ->
        require Logger
        Logger.error("Retry query failed: #{inspect(reason)}")
        []
    end
  end

  defp interleave_contacts([], right), do: right
  defp interleave_contacts(left, []), do: left

  defp interleave_contacts([l | lt], [r | rt]) do
    [l, r | interleave_contacts(lt, rt)]
  end

  defp last_contact_id_or(current, []), do: current
  defp last_contact_id_or(_current, contacts), do: contacts |> List.last() |> Map.get(:id)

  defp push_to_redis(contacts, phone_number_id, campaign_id) do
    queue_name = "queue:sending:#{campaign_id}:#{phone_number_id}"

    commands =
      Enum.map(contacts, fn contact ->
        payload =
          Jason.encode!(%{
            contact_id: contact.id,
            phone: contact.phone,
            name: contact.name,
            variables: contact.variables
          })

        ["RPUSH", queue_name, payload]
      end)

    case Redix.pipeline(:redix, commands) do
      {:ok, _results} ->
        length(contacts)

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
