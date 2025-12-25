defmodule TitanFlow.Campaigns.WebhookBatcher do
  @moduledoc """
  P2 FIX: Batches webhook status updates to reduce DB load.

  Instead of doing a Repo.update per webhook (which saturates the DB pool),
  webhooks push status updates to Redis and this GenServer flushes them
  in batches every 2 seconds using a true batch UPDATE.

  ## Key Features:
  - Stores only the LATEST status per meta_message_id (sent→delivered→read is monotonic)
  - TRUE batch updates via UPDATE ... FROM (VALUES ...)
  - Preserves delivered_at/read_at timestamps
  - Calls error triggers for failed statuses
  - Handles log-not-found with proper requeue logic
  """
  use GenServer
  require Logger

  alias TitanFlow.Repo
  alias TitanFlow.Campaigns.MessageTracking

  @flush_interval_ms 2_000
  @batch_size 800
  @buffer_key "buffer:webhook_updates"
  # Drop updates older than 30s
  @requeue_ttl_ms 30_000

  # Status priority (higher = more final)
  @status_priority %{
    "sent" => 1,
    "delivered" => 2,
    "read" => 3,
    # Failed is terminal
    "failed" => 4
  }

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Queue a webhook status update for batch processing.
  Returns immediately - does not block on DB.
  """
  def queue_status_update(
        meta_message_id,
        status,
        timestamp,
        error_code \\ nil,
        error_message \\ nil
      ) do
    update = %{
      "meta_message_id" => meta_message_id,
      "status" => status,
      "timestamp" => timestamp,
      "error_code" => error_code,
      "error_message" => error_message,
      "queued_at" => System.system_time(:millisecond)
    }

    enqueue_update(update)
  end

  # --- Server Callbacks ---

  @impl true
  def init(_opts) do
    Logger.info("WebhookBatcher started, flushing every #{@flush_interval_ms}ms")
    schedule_flush()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:flush, state) do
    flush_updates()
    schedule_flush()
    {:noreply, state}
  end

  @impl true
  def handle_info({:requeue, update}, state) do
    # Requeue an update that failed (log not found yet), preserving queued_at
    requeue_update(update)
    {:noreply, state}
  end

  @impl true
  def terminate(reason, _state) do
    Logger.info("WebhookBatcher shutting down (#{inspect(reason)}), draining buffer...")
    drain_buffer()
    Logger.info("WebhookBatcher drain complete")
    :ok
  end

  # --- Private Functions ---

  defp schedule_flush do
    Process.send_after(self(), :flush, @flush_interval_ms)
  end

  defp enqueue_update(update) do
    case Redix.command(:redix, ["RPUSH", @buffer_key, Jason.encode!(update)]) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.error("WebhookBatcher: Failed to queue update: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp requeue_update(update) do
    update_map = %{
      "meta_message_id" => update.meta_message_id,
      "status" => update.status,
      "timestamp" => update.raw_timestamp || update.timestamp,
      "error_code" => update.error_code,
      "error_message" => update.error_message,
      "queued_at" => update.queued_at || System.system_time(:millisecond)
    }

    enqueue_update(update_map)
  end

  defp flush_updates do
    case Redix.command(:redix, ["LPOP", @buffer_key, @batch_size]) do
      {:ok, nil} ->
        0

      {:ok, []} ->
        0

      {:ok, raw_entries} when is_list(raw_entries) ->
        process_batch(raw_entries)

      {:error, reason} ->
        Logger.error("WebhookBatcher: Redis LPOP failed: #{inspect(reason)}")
        0
    end
  end

  defp drain_buffer do
    case flush_updates() do
      0 -> :ok
      _ -> drain_buffer()
    end
  end

  defp process_batch(raw_entries) do
    # Decode and deduplicate (keep highest priority status per message_id)
    updates =
      raw_entries
      |> Enum.map(&decode_update/1)
      |> Enum.reject(&is_nil/1)
      |> deduplicate_by_message_id()

    if length(updates) > 0 do
      Logger.debug("WebhookBatcher: Processing #{length(updates)} unique updates")

      # FIX #5: True batch update instead of per-row updates
      apply_batch_update(updates)

      length(updates)
    else
      0
    end
  end

  # FIX #1: Preserve queued_at through decode
  defp decode_update(json_string) do
    case Jason.decode(json_string) do
      {:ok, map} ->
        %{
          meta_message_id: map["meta_message_id"],
          status: map["status"],
          timestamp: parse_timestamp(map["timestamp"]),
          raw_timestamp: map["timestamp"],
          error_code: map["error_code"],
          error_message: map["error_message"],
          # FIX #1: Keep queued_at
          queued_at: map["queued_at"]
        }

      {:error, reason} ->
        Logger.error("WebhookBatcher: Failed to decode: #{inspect(reason)}")
        nil
    end
  end

  defp parse_timestamp(nil), do: nil

  defp parse_timestamp(ts) when is_integer(ts) do
    DateTime.from_unix!(ts) |> DateTime.truncate(:second)
  end

  defp parse_timestamp(ts) when is_binary(ts) do
    case Integer.parse(ts) do
      {unix, _} -> DateTime.from_unix!(unix) |> DateTime.truncate(:second)
      :error -> nil
    end
  end

  # Keep only the highest priority status per message_id
  defp deduplicate_by_message_id(updates) do
    updates
    |> Enum.group_by(& &1.meta_message_id)
    |> Enum.map(fn {_id, group} ->
      Enum.max_by(group, fn u ->
        @status_priority[u.status] || 0
      end)
    end)
  end

  # FIX #5: True batch UPDATE using UNNEST
  defp apply_batch_update(updates) do
    # First, verify which logs exist
    message_ids = Enum.map(updates, & &1.meta_message_id)

    existing_logs = fetch_existing_logs(message_ids)
    existing_ids = MapSet.new(Enum.map(existing_logs, & &1.meta_message_id))

    # Split into found and not-found
    {found_updates, missing_updates} =
      Enum.split_with(updates, fn u ->
        MapSet.member?(existing_ids, u.meta_message_id)
      end)

    # Process found updates in batch
    if length(found_updates) > 0 do
      batch_update_logs(found_updates, existing_logs)
    end

    # FIX #4: Requeue only truly missing (with proper TTL check)
    Enum.each(missing_updates, &maybe_requeue/1)
  end

  # Fetch existing logs with campaign_id and phone_number_id for error triggers
  defp fetch_existing_logs(message_ids) do
    sql = """
    SELECT meta_message_id, id, campaign_id, phone_number_id, recipient_phone, template_name, status
    FROM message_logs
    WHERE meta_message_id = ANY($1)
    """

    case Repo.query(sql, [message_ids]) do
      {:ok, %{rows: rows, columns: columns}} ->
        Enum.map(rows, fn row ->
          columns
          |> Enum.zip(row)
          |> Enum.into(%{}, fn {col, val} -> {String.to_atom(col), val} end)
        end)

      {:error, reason} ->
        Logger.error("WebhookBatcher: Failed to fetch logs: #{inspect(reason)}")
        []
    end
  end

  # FIX #2 & #5: Batch update with proper timestamps
  defp batch_update_logs(updates, existing_logs) do
    # Create lookup for existing logs
    log_lookup = Map.new(existing_logs, fn l -> {l.meta_message_id, l} end)

    # Build VALUES for batch update
    # We need to handle each status type separately for timestamps
    {delivered_updates, other_updates} = Enum.split_with(updates, &(&1.status == "delivered"))
    {read_updates, remaining} = Enum.split_with(other_updates, &(&1.status == "read"))
    {failed_updates, sent_updates} = Enum.split_with(remaining, &(&1.status == "failed"))

    # Apply each type of update
    apply_delivered_batch(delivered_updates)
    apply_read_batch(read_updates)
    apply_sent_batch(sent_updates)
    apply_failed_batch(failed_updates, log_lookup)
  end

  # FIX #2: Set delivered_at for delivered status
  defp apply_delivered_batch([]), do: :ok

  defp apply_delivered_batch(updates) do
    sql = """
    UPDATE message_logs
    SET status = 'delivered',
        delivered_at = v.ts,
        updated_at = NOW()
    FROM (SELECT unnest($1::text[]) as mid, unnest($2::timestamptz[]) as ts) v
    WHERE message_logs.meta_message_id = v.mid
      AND message_logs.status IN ('sent')
    """

    ids = Enum.map(updates, & &1.meta_message_id)
    timestamps = Enum.map(updates, fn u -> u.timestamp || DateTime.utc_now() end)

    case Repo.query(sql, [ids, timestamps]) do
      {:ok, %{num_rows: n}} ->
        if n > 0, do: Logger.debug("WebhookBatcher: Updated #{n} to delivered")

      {:error, reason} ->
        Logger.error("WebhookBatcher: Delivered batch failed: #{inspect(reason)}")
    end
  end

  # FIX #2: Set read_at for read status
  defp apply_read_batch([]), do: :ok

  defp apply_read_batch(updates) do
    sql = """
    UPDATE message_logs
    SET status = 'read',
        read_at = v.ts,
        updated_at = NOW()
    FROM (SELECT unnest($1::text[]) as mid, unnest($2::timestamptz[]) as ts) v
    WHERE message_logs.meta_message_id = v.mid
      AND message_logs.status IN ('sent', 'delivered')
    """

    ids = Enum.map(updates, & &1.meta_message_id)
    timestamps = Enum.map(updates, fn u -> u.timestamp || DateTime.utc_now() end)

    case Repo.query(sql, [ids, timestamps]) do
      {:ok, %{num_rows: n}} ->
        if n > 0, do: Logger.debug("WebhookBatcher: Updated #{n} to read")

      {:error, reason} ->
        Logger.error("WebhookBatcher: Read batch failed: #{inspect(reason)}")
    end
  end

  defp apply_sent_batch([]), do: :ok

  defp apply_sent_batch(updates) do
    # Sent status rarely comes from webhooks (usually set by LogBatcher)
    # But handle it for completeness
    sql = """
    UPDATE message_logs
    SET status = 'sent', updated_at = NOW()
    FROM (SELECT unnest($1::text[]) as mid) v
    WHERE message_logs.meta_message_id = v.mid
      AND message_logs.status IS NULL
    """

    ids = Enum.map(updates, & &1.meta_message_id)
    Repo.query(sql, [ids])
  end

  # FIX #3: Handle failed with error triggers
  defp apply_failed_batch([], _log_lookup), do: :ok

  defp apply_failed_batch(updates, log_lookup) do
    sql = """
    UPDATE message_logs
    SET status = 'failed',
        error_code = COALESCE(v.err_code, error_code),
        error_message = COALESCE(v.err_msg, error_message),
        updated_at = NOW()
    FROM (SELECT unnest($1::text[]) as mid, 
                 unnest($2::text[]) as err_code, 
                 unnest($3::text[]) as err_msg) v
    WHERE message_logs.meta_message_id = v.mid
      AND message_logs.status <> 'failed'
    RETURNING message_logs.meta_message_id
    """

    ids = Enum.map(updates, & &1.meta_message_id)
    error_codes = Enum.map(updates, &normalize_error_code/1)
    error_messages = Enum.map(updates, & &1.error_message)

    case Repo.query(sql, [ids, error_codes, error_messages]) do
      {:ok, %{rows: rows}} ->
        updated_ids = Enum.map(rows, fn [mid] -> mid end)

        if length(updated_ids) > 0 do
          Logger.debug("WebhookBatcher: Updated #{length(updated_ids)} to failed")
        end

        # FIX #3: Call error triggers for each failed update
        Enum.each(updates, fn update ->
          if update.meta_message_id in updated_ids do
            case Map.get(log_lookup, update.meta_message_id) do
              nil ->
                :ok

              log ->
                # Call error triggers (blacklist, rotation, template tracking)
                MessageTracking.handle_webhook_error(
                  log.campaign_id,
                  log.phone_number_id,
                  update.error_code,
                  log.recipient_phone,
                  log.template_name
                )
            end
          end
        end)

      {:error, reason} ->
        Logger.error("WebhookBatcher: Failed batch failed: #{inspect(reason)}")
    end
  end

  # FIX #4: Proper requeue with TTL check
  defp maybe_requeue(update) do
    age_ms = System.system_time(:millisecond) - (update.queued_at || 0)

    if age_ms < @requeue_ttl_ms do
      # Log not found yet (LogBatcher hasn't flushed), requeue
      Process.send_after(self(), {:requeue, update}, 1_000)
    else
      # Update is stale, drop it
      Logger.warning(
        "WebhookBatcher: Dropping stale update for #{update.meta_message_id} (age: #{age_ms}ms)"
      )
    end
  end

  defp normalize_error_code(update) do
    case update.error_code do
      nil -> nil
      code -> to_string(code)
    end
  end
end
