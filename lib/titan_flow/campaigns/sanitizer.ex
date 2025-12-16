defmodule TitanFlow.Campaigns.Sanitizer do
  @moduledoc """
  The "Smart Deduplication" module.
  
  Removes contacts from a campaign that have been contacted recently,
  using the contact_history table for instant lookups.
  
  ## Performance
  The contact_history table is a lightweight "Master History Table" that
  contains one row per phone number with the last contact timestamp.
  This is ~100x faster than scanning the massive message_logs table.
  """

  require Logger

  alias TitanFlow.Repo
  alias TitanFlow.Campaigns

  # 5 minute timeout for large dataset operations
  @query_timeout 300_000

  @doc """
  Apply deduplication to a campaign based on its dedup_window_days setting.
  
  If dedup_window_days > 0:
  - Deletes contacts whose phone numbers appear in contact_history within the window
  - Updates campaign.skipped_count with the number of removed contacts
  
  Returns {:ok, skipped_count} or {:error, reason}
  """
  @spec apply_deduplication(integer()) :: {:ok, integer()} | {:error, term()}
  def apply_deduplication(campaign_id) do
    campaign = Campaigns.get_campaign!(campaign_id)
    
    if campaign.dedup_window_days > 0 do
      Logger.info("Sanitizer: Applying #{campaign.dedup_window_days}-day deduplication for campaign #{campaign_id}")
      
      start_time = System.monotonic_time(:millisecond)
      skipped_count = delete_recently_contacted(campaign_id, campaign.dedup_window_days)
      elapsed = System.monotonic_time(:millisecond) - start_time
      
      # Update campaign with skipped count
      Campaigns.update_campaign(campaign, %{skipped_count: skipped_count})
      
      Logger.info("Sanitizer: Removed #{skipped_count} contacts from campaign #{campaign_id} (contacted in last #{campaign.dedup_window_days} days) in #{elapsed}ms")
      
      {:ok, skipped_count}
    else
      Logger.info("Sanitizer: Deduplication disabled for campaign #{campaign_id}")
      {:ok, 0}
    end
  end

  @doc """
  Delete contacts from a campaign that have been contacted in the last N days.
  
  Uses the contact_history table for instant lookups instead of scanning message_logs.
  This is ~100x faster for large datasets.
  
  Returns the count of deleted contacts.
  """
  def delete_recently_contacted(campaign_id, days) do
    # Calculate the cutoff timestamp
    cutoff = DateTime.utc_now() |> DateTime.add(-days * 24 * 3600, :second)
    
    # Use contact_history for instant deduplication (instead of message_logs)
    # This is ~100x faster because contact_history has 1 row per phone vs millions in message_logs
    sql = """
    WITH deleted_rows AS (
      DELETE FROM contacts
      WHERE campaign_id = $1
      AND phone IN (
        SELECT phone_number 
        FROM contact_history
        WHERE last_sent_at > $2
      )
      RETURNING id
    )
    SELECT count(*) FROM deleted_rows
    """
    
    case Repo.query(sql, [campaign_id, cutoff], timeout: @query_timeout) do
      {:ok, %{rows: [[count]]}} ->
        count
        
      {:error, reason} ->
        Logger.error("Sanitizer: Failed to delete duplicates: #{inspect(reason)}")
        0
    end
  end

  @doc """
  Get count of contacts that would be removed without actually removing them.
  Useful for preview/dry-run functionality.
  """
  def preview_deduplication(campaign_id, days) do
    cutoff = DateTime.utc_now() |> DateTime.add(-days * 24 * 3600, :second)
    
    sql = """
    SELECT count(*) FROM contacts
    WHERE campaign_id = $1
    AND phone IN (
      SELECT phone_number 
      FROM contact_history
      WHERE last_sent_at > $2
    )
    """
    
    case Repo.query(sql, [campaign_id, cutoff], timeout: @query_timeout) do
      {:ok, %{rows: [[count]]}} -> {:ok, count}
      {:error, reason} -> {:error, reason}
    end
  end
end
