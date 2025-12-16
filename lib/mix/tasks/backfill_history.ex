defmodule Mix.Tasks.TitanFlow.BackfillHistory do
  @moduledoc """
  Backfill the contact_history table from existing message_logs data.
  
  This task populates the contact_history table with the most recent
  sent_at timestamp for each unique recipient_phone from message_logs.
  
  ## Usage
  
      mix titan_flow.backfill_history
      
  ## What it does
  
  1. Queries all unique recipient_phone numbers from message_logs
  2. Gets the MAX(sent_at) for each phone number
  3. Inserts into contact_history (or updates if exists)
  
  This is safe to run multiple times - uses ON CONFLICT DO UPDATE.
  """
  use Mix.Task

  require Logger

  @shortdoc "Backfill contact_history table from message_logs"

  @impl Mix.Task
  def run(_args) do
    # Start the application to get database connection
    Mix.Task.run("app.start")

    Logger.info("Starting contact_history backfill...")
    
    start_time = System.monotonic_time(:millisecond)
    
    # Use raw SQL for maximum performance
    sql = """
    INSERT INTO contact_history (phone_number, last_sent_at, last_campaign_id, inserted_at, updated_at)
    SELECT 
      recipient_phone,
      MAX(sent_at),
      (SELECT campaign_id FROM message_logs m2 
       WHERE m2.recipient_phone = message_logs.recipient_phone 
       ORDER BY sent_at DESC LIMIT 1),
      NOW(),
      NOW()
    FROM message_logs
    WHERE recipient_phone IS NOT NULL
    GROUP BY recipient_phone
    ON CONFLICT (phone_number) 
    DO UPDATE SET 
      last_sent_at = GREATEST(contact_history.last_sent_at, EXCLUDED.last_sent_at),
      last_campaign_id = EXCLUDED.last_campaign_id,
      updated_at = NOW()
    """

    case TitanFlow.Repo.query(sql, [], timeout: 600_000) do
      {:ok, result} ->
        elapsed = System.monotonic_time(:millisecond) - start_time
        Logger.info("Backfill complete!")
        Logger.info("  Rows affected: #{result.num_rows}")
        Logger.info("  Time elapsed: #{elapsed}ms")
        
        # Print a summary
        count_result = TitanFlow.Repo.query!("SELECT COUNT(*) FROM contact_history")
        [[count]] = count_result.rows
        Logger.info("  Total records in contact_history: #{count}")
        
      {:error, error} ->
        Logger.error("Backfill failed: #{inspect(error)}")
        Mix.raise("Failed to backfill contact_history: #{inspect(error)}")
    end
  end
end
