defmodule TitanFlow.Campaigns.MessageTracking do
  @moduledoc """
  Tracks message statuses from webhooks and updates campaign statistics.
  
  ## Flow:
  1. When message is sent, Pipeline calls `record_sent/4` to create a MessageLog
  2. When webhook arrives, WebhookController calls `update_status/2`
  3. MessageTracking updates the log and increments campaign counters
  4. When all messages are processed, campaign is marked completed
  """

  import Ecto.Query
  alias TitanFlow.Repo
  alias TitanFlow.Campaigns
  alias TitanFlow.Campaigns.{Campaign, MessageLog, Orchestrator}

  require Logger

  @doc """
  Record a sent message - called by Pipeline when message is dispatched.
  SAFE: This function NEVER raises - always returns :ok even on failure.
  Uses Postgres only.
  """
  def record_sent(meta_message_id, campaign_id, contact_id, recipient_phone, template_name, phone_number_id \\ nil) do
    attrs = %{
      meta_message_id: meta_message_id,
      campaign_id: campaign_id,
      contact_id: contact_id,
      recipient_phone: recipient_phone,
      template_name: template_name,
      phone_number_id: phone_number_id,
      status: "sent",
      sent_at: DateTime.utc_now()
    }

    try do
      result = do_record_sent(attrs, campaign_id)
      case result do
        {:ok, _log} -> :ok
        {:error, reason} ->
          Logger.error("Failed to record sent message #{meta_message_id}: #{inspect(reason)}")
          :ok
      end
    rescue
      Ecto.ConstraintError ->
        # Foreign key error on contact_id - retry without it
        Logger.warning("Foreign key error for contact_id #{contact_id}, retrying without contact_id")
        try do
          attrs_without_contact = Map.delete(attrs, :contact_id)
          do_record_sent(attrs_without_contact, campaign_id)
          :ok
        rescue
          e ->
            Logger.error("Failed to record sent message (retry) #{meta_message_id}: #{inspect(e)}")
            :ok
        end
      e ->
        Logger.error("Failed to record sent message #{meta_message_id}: #{inspect(e)}")
        :ok
    end
  end

  defp do_record_sent(attrs, campaign_id) do
    %MessageLog{}
    |> MessageLog.changeset(attrs)
    |> Repo.insert(on_conflict: :nothing)
    |> case do
      {:ok, log} ->
        # Increment sent count
        increment_campaign_counter(campaign_id, :sent_count)
        
        # Update contact_history for instant deduplication (fire-and-forget)
        if attrs.recipient_phone do
          Task.start(fn -> upsert_contact_history(attrs.recipient_phone, campaign_id) end)
        end
        
        {:ok, log}
      
      {:error, _changeset} = error ->
        error
    end
  end

  @doc """
  Record a failed message - called by Pipeline when API returns an error.
  This ensures failed messages are tracked in the database with error details.
  ALSO triggers template fallback and phone rotation for critical error codes.
  SAFE: This function NEVER raises - always returns :ok even on failure.
  """
  def record_failed(campaign_id, contact_id, recipient_phone, template_name, error_code, error_message, phone_number_id \\ nil) do
    attrs = %{
      meta_message_id: "failed_#{System.unique_integer([:positive])}",  # Unique ID for failed messages
      campaign_id: campaign_id,
      contact_id: contact_id,
      recipient_phone: recipient_phone,
      template_name: template_name,
      phone_number_id: phone_number_id,
      status: "failed",
      error_code: to_string(error_code),  # Ensure string for matching
      error_message: error_message,
      sent_at: DateTime.utc_now()
    }

    try do
      result = %MessageLog{}
        |> MessageLog.changeset(attrs)
        |> Repo.insert(on_conflict: :nothing)
      
      case result do
        {:ok, log} ->
          # Increment failed count
          increment_campaign_counter(campaign_id, :failed_count)
          Logger.warning("Recorded failed message for #{recipient_phone}: #{error_code} - #{error_message}")
          
          # CRITICAL: Trigger template fallback / phone rotation for critical errors
          # This handles sync API errors (132001, 132016, 132015 for templates; 131042, 131048 for phones)
          handle_error_triggers(campaign_id, phone_number_id, error_code, log)
          
          :ok
        {:error, reason} ->
          Logger.error("Failed to record failed message: #{inspect(reason)}")
          :ok
      end
    rescue
      e ->
        Logger.error("Exception recording failed message: #{inspect(e)}")
        :ok
    end
  end

  @doc """
  Upsert contact_history for instant deduplication.
  Called after each message is sent to keep the history table current.
  """
  def upsert_contact_history(phone_number, campaign_id) do
    now = DateTime.utc_now()
    
    sql = """
    INSERT INTO contact_history (phone_number, last_sent_at, last_campaign_id, inserted_at, updated_at)
    VALUES ($1, $2, $3, $2, $2)
    ON CONFLICT (phone_number) 
    DO UPDATE SET 
      last_sent_at = $2,
      last_campaign_id = $3,
      updated_at = $2
    """
    
    case Repo.query(sql, [phone_number, now, campaign_id]) do
      {:ok, _} -> :ok
      {:error, reason} ->
        Logger.warning("Failed to upsert contact_history for #{phone_number}: #{inspect(reason)}")
        :ok
    end
  end

  @doc """
  Update message status from webhook - called by WebhookController.
  Handles: sent, delivered, read, failed statuses.
  """
  def update_status(meta_message_id, status, opts \\ []) do
    timestamp = Keyword.get(opts, :timestamp, DateTime.utc_now())
    error_code = Keyword.get(opts, :error_code)
    error_message = Keyword.get(opts, :error_message)

    case Repo.get_by(MessageLog, meta_message_id: meta_message_id) do
      nil ->
        Logger.debug("Message #{meta_message_id} not found, creating new log")
        {:ok, :not_tracked}

      log ->
        update_log_and_counters(log, status, timestamp, error_code, error_message)
    end
  end

  @doc """
  Record a reply from a user.
  Attributes the reply to the most recent campaign message sent to this user.
  Only counts UNIQUE replies - if user already replied, don't increment again.
  """
  def record_reply(_phone_number_id, sender_phone) do
    # Find last sent message log to attribute the reply
    # Only match on recipient_phone to avoid format mismatches
    query = from m in MessageLog,
      where: m.recipient_phone == ^sender_phone,
      order_by: [desc: m.sent_at],
      limit: 1

    case Repo.one(query) do
      %MessageLog{campaign_id: campaign_id, has_replied: has_replied} = log when not is_nil(campaign_id) ->
        # Only count if this is the FIRST reply from this user
        if not has_replied do
          # Mark as replied to prevent future double-counting
          log
          |> Ecto.Changeset.change(%{has_replied: true})
          |> Repo.update()
          
          # Increment reply counter
          increment_campaign_counter(campaign_id, :replied_count)
        end
        :ok
      _ ->
        :ignore
    end
  end

  @doc """
  Get real-time campaign statistics from message_logs.
  Counts are cumulative: delivered includes read, sent includes all.
  
  Status progression: sent → delivered → read
  - sent_count = total messages in system (all statuses)
  - delivered_count = messages that reached "delivered" OR "read" status
  - read_count = messages at "read" status only
  """
  def get_realtime_stats(campaign_id) do
    # 1. Get the LATEST status for each unique phone number in this campaign
    # This prevents double-counting retries (e.g. failed -> delivered counts as 1 delivered)
    latest_status_query = from m in MessageLog,
      where: m.campaign_id == ^campaign_id,
      # DISTINCT ON ensures we get one row per recipient
      distinct: m.recipient_phone,
      # Order by sent_at DESC ensures we get the LATEST row
      order_by: [desc: m.recipient_phone, desc: m.sent_at],
      select: %{status: m.status, has_replied: m.has_replied}

    # 2. Aggregate counts from the unique statuses
    query = from s in subquery(latest_status_query),
      group_by: s.status,
      select: {s.status, count(s.status)}

    status_counts = Repo.all(query) |> Map.new()
    
    # Extract unique counts
    sent_status = Map.get(status_counts, "sent", 0)
    delivered_status = Map.get(status_counts, "delivered", 0)
    read_status = Map.get(status_counts, "read", 0)
    failed_status = Map.get(status_counts, "failed", 0)
    
    # 3. Calculate Cumulative Counts (simulating a funnel)
    # Total Unique Sent = Sum of all unique reachable outcomes
    total_sent = sent_status + delivered_status + read_status + failed_status
    
    # Total Unique Delivered = delivered + read
    total_delivered = delivered_status + read_status
    
    # Total Unique Read = read (primary) OR unique replies (secondary signal)
    replied_count = get_replied_count_from_logs(campaign_id)
    total_read = max(read_status, replied_count)
    
    # Ensure consistency (Delivered >= Read)
    total_delivered = max(total_delivered, total_read)
    
    %{
      sent_count: total_sent,
      delivered_count: total_delivered,
      read_count: total_read,
      replied_count: replied_count,
      failed_count: failed_status
    }
  end

  # Count actual replied messages from message_logs (source of truth)
  defp get_replied_count_from_logs(campaign_id) do
    from(m in MessageLog,
      where: m.campaign_id == ^campaign_id and m.has_replied == true,
      select: count(m.id)
    )
    |> Repo.one() || 0
  end

  defp to_int(nil), do: 0
  defp to_int(val) when is_binary(val), do: String.to_integer(val)
  defp to_int(val) when is_integer(val), do: val

  defp get_db_stats_struct(campaign_id) do
    # Also use accurate counting for DB stats
    get_realtime_stats(campaign_id)
  end

  defp populate_redis_stats(campaign_id, stats) do
    commands = [
      ["SET", "campaign:#{campaign_id}:sent_count", stats.sent_count],
      ["SET", "campaign:#{campaign_id}:delivered_count", stats.delivered_count],
      ["SET", "campaign:#{campaign_id}:read_count", stats.read_count],
      ["SET", "campaign:#{campaign_id}:replied_count", stats.replied_count],
      ["SET", "campaign:#{campaign_id}:failed_count", stats.failed_count]
    ]
    Redix.pipeline(:redix, commands)
  end

  @doc """
  Get message statuses broken down by template.
  Includes replied count from has_replied field.
  """
  def get_template_breakdown(campaign_id) do
    # Get status counts per template
    status_query = from m in MessageLog,
      where: m.campaign_id == ^campaign_id,
      group_by: [m.template_name, m.status],
      select: {m.template_name, m.status, count(m.id)}

    status_results = Repo.all(status_query)
    
    # Get replied counts per template (has_replied = true)
    replied_query = from m in MessageLog,
      where: m.campaign_id == ^campaign_id and m.has_replied == true,
      group_by: m.template_name,
      select: {m.template_name, count(m.id)}
    
    replied_counts = Repo.all(replied_query) |> Map.new()

    # Combine status and replied counts
    status_results
    |> Enum.group_by(fn {name, _, _} -> name end)
    |> Map.new(fn {name, stats} ->
      counts = Enum.reduce(stats, %{}, fn {_, status, count}, acc ->
        Map.put(acc, status, count)
      end)
      # Add replied count from has_replied field
      counts = Map.put(counts, "replied", Map.get(replied_counts, name, 0))
      {name, counts}
    end)
  end

  # ... existing functions ...

  @doc """
  Check if campaign is complete and update status if needed.
  Also syncs Redis counters to DB for persistence.
  """
  def check_campaign_completion(campaign_id) do
    # First sync Redis counters to DB
    sync_counters_to_db(campaign_id)
    
    # Now check with fresh DB data
    campaign = Campaigns.get_campaign!(campaign_id)
    
    # Check if already completed to avoid updating timestamp
    if campaign.status == "completed" do
      {:ok, campaign}
    else
      total_processed = (campaign.sent_count || 0) + (campaign.failed_count || 0)
      total_records = campaign.total_records || 0

      if total_processed >= total_records and total_records > 0 do
        Logger.info("Campaign #{campaign_id} completed: #{total_processed}/#{total_records} processed")
        Campaigns.update_campaign(campaign, %{status: "completed", completed_at: NaiveDateTime.utc_now()})
      else
        {:ok, campaign}
      end
    end
  end

  defp sync_counters_to_db(campaign_id) do
    # 1. Calculate accurate stats from MessageLogs (Source of Truth)
    stats = get_realtime_stats(campaign_id)
    
    # 2. Update Redis keys to match reality (healing drift)
    populate_redis_stats(campaign_id, stats)

    # 3. Update DB Campaign record
    from(c in Campaign, where: c.id == ^campaign_id)
    |> Repo.update_all(set: [
      sent_count: stats.sent_count,
      delivered_count: stats.delivered_count,
      read_count: stats.read_count,
      replied_count: stats.replied_count,
      failed_count: stats.failed_count
    ])
    
    stats
  end

  # Private functions

  defp update_log_and_counters(log, status, timestamp, error_code, error_message) do
    # Determine which timestamp field to update
    timestamp_field = case status do
      "delivered" -> :delivered_at
      "read" -> :read_at
      _ -> nil
    end

    # Build update attrs
    attrs = %{status: status}
    attrs = if timestamp_field, do: Map.put(attrs, timestamp_field, timestamp), else: attrs
    attrs = if error_code, do: Map.put(attrs, :error_code, error_code), else: attrs
    attrs = if error_message, do: Map.put(attrs, :error_message, error_message), else: attrs

    # Update the log
    {:ok, updated_log} = log
    |> MessageLog.changeset(attrs)
    |> Repo.update()

    # Update campaign counters
    if log.campaign_id do
      update_campaign_counters(log.campaign_id, log.status, status)
      
      # Handle critical errors (Rotation / Fallback)
      if status == "failed" do
        handle_error_triggers(log.campaign_id, log.phone_number_id, error_code, log)
      end
      
      # Check for completion if this was a terminal status
      if status in ["sent", "delivered", "read", "failed"] do
        check_campaign_completion(log.campaign_id)
      end
    end

    {:ok, updated_log}
  end

  # Error Handling Logic
  
  # Error Handling Logic
  
  # Removed 131005 as requested
  @phone_rotation_codes ["131042", "131048", "130429"]
  @template_switch_codes ["132001", "132016", "132015"]
  @error_threshold 10
  @template_error_threshold 5

  defp handle_error_triggers(campaign_id, phone_number_id, error_code, log) do
    # Convert integer codes to string for consistency
    code = to_string(error_code)

    cond do
      code == "131026" ->
        # Smart Blacklisting
        blacklist_contact(log.recipient_phone, campaign_id)

      code in @phone_rotation_codes ->
        track_phone_error(campaign_id, phone_number_id, code)

      code in @template_switch_codes ->
        track_template_error(campaign_id, log.template_name)

      true ->
        :ok
    end
  end

  defp blacklist_contact(phone, campaign_id) do
    if phone do
      Logger.info("Blacklisting invalid number #{phone} from campaign #{campaign_id}")
      # Mark contacts with this phone as blacklisted for future imports
      from(c in "contacts", where: c.phone == ^phone)
      |> Repo.update_all(set: [is_blacklisted: true])
    end
  end

  defp track_phone_error(campaign_id, phone_number_id, code) do
    key = "campaign:#{campaign_id}:phone:#{phone_number_id}:critical_errors"
    
    case Redix.command(:redix, ["INCR", key]) do
      {:ok, count} when count >= @error_threshold ->
        Logger.warning("Campaign #{campaign_id}: Error threshold (#{code}) reached for phone #{phone_number_id}")
        
        campaign = Campaigns.get_campaign!(campaign_id)
        phone_ids = campaign.phone_ids || []
        
        handle_phone_rotation(campaign_id, phone_number_id, phone_ids, code)
        
      _ -> :ok
    end
  end

  defp track_template_error(campaign_id, template_name) do
    key = "campaign:#{campaign_id}:template:#{template_name}:errors"
    
    case Redix.command(:redix, ["INCR", key]) do
      {:ok, count} when count >= @template_error_threshold ->
        campaign = Campaigns.get_campaign!(campaign_id)
        
        current_template = if campaign.primary_template, do: campaign.primary_template.name
        
        if current_template == template_name and campaign.fallback_template_id do
          Logger.warning("Campaign #{campaign_id}: Template #{template_name} failing, switching to fallback")
          
          # Switch Primary Template to Fallback
          Campaigns.update_campaign(campaign, %{
            primary_template_id: campaign.fallback_template_id,
            error_message: "Auto-switched template due to Meta errors"
          })
          
          # Trigger retry for failed template messages
          Task.start(fn -> 
            TitanFlow.Campaigns.RetryManager.retry_template_failure(template_name, campaign_id, campaign.fallback_template_id)
          end)
          
          Redix.command(:redix, ["DEL", key])
        else
           if is_nil(campaign.fallback_template_id) do
             Logger.warning("Campaign #{campaign_id}: Template failing but no fallback configured. Pausing.")
             Orchestrator.pause_campaign(campaign_id)
           end
        end
        
      _ -> :ok
    end
  end

  defp handle_phone_rotation(campaign_id, failed_phone_id, phone_ids, code) do
    alias TitanFlow.Campaigns.RetryManager
    
    Redix.command(:redix, ["SADD", "campaign:#{campaign_id}:exhausted_phones", failed_phone_id])
    
    {:ok, exhausted} = Redix.command(:redix, ["SMEMBERS", "campaign:#{campaign_id}:exhausted_phones"])
    exhausted_count = length(exhausted || [])
    
    if exhausted_count >= length(phone_ids) do
      # All phones exhausted logic
      reason = if code == "130429", do: "Rate Limit Backoff", else: "All phones exhausted"
      
      Logger.warning("Campaign #{campaign_id}: #{reason}, pausing")
      
      # Update campaign with specific error message
      campaign = Campaigns.get_campaign!(campaign_id)
      Campaigns.update_campaign(campaign, %{error_message: reason})
      Orchestrator.pause_campaign(campaign_id)
    else
      Logger.info("Campaign #{campaign_id}: Rotating phone #{failed_phone_id}. #{length(phone_ids) - exhausted_count} remaining.")
      
      Task.start(fn ->
        RetryManager.process_exhausted_phone(failed_phone_id, campaign_id)
      end)
    end
  end

  defp update_campaign_counters(campaign_id, old_status, new_status) do
    # Only update if status actually changed
    if old_status != new_status do
      case new_status do
        "delivered" ->
          increment_campaign_counter(campaign_id, :delivered_count)
        
        "read" ->
          # If coming from sent, also count as delivered (for consistency)
          if old_status == "sent" do
            increment_campaign_counter(campaign_id, :delivered_count)
          end
          increment_campaign_counter(campaign_id, :read_count)
        
        "failed" ->
          increment_campaign_counter(campaign_id, :failed_count)
          # Decrement sent count since it failed
          decrement_campaign_counter(campaign_id, :sent_count)
        
        _ ->
          :ok
      end
    end
  end

  defp increment_campaign_counter(campaign_id, field) do
    # Redis-only for high concurrency (microsecond latency)
    # DB sync happens asynchronously via check_campaign_completion
    Redix.command(:redix, ["INCR", "campaign:#{campaign_id}:#{field}"])
    :ok
  end

  defp decrement_campaign_counter(campaign_id, field) do
    # Redis-only for consistency with increment
    Redix.command(:redix, ["DECR", "campaign:#{campaign_id}:#{field}"])
    :ok
  end

  @doc """
  Get failed messages for a campaign with error details.
  Returns list of maps with: recipient_phone, error_code, error_message, sent_at
  """
  def get_failed_messages(campaign_id, limit \\ 100) do
    from(m in MessageLog,
      where: m.campaign_id == ^campaign_id and m.status == "failed",
      order_by: [desc: m.sent_at],
      limit: ^limit,
      select: %{
        recipient_phone: m.recipient_phone,
        error_code: m.error_code,
        error_message: m.error_message,
        sent_at: m.sent_at
      }
    )
    |> Repo.all()
  end
end
