defmodule TitanFlow.Campaigns.Orchestrator do
  @moduledoc """
  Orchestrates the full campaign execution flow:
  1. Import CSV contacts
  2. Distribute contacts to per-phone Redis queues (via Runner)
  3. Start Broadway Pipelines for each phone number
  4. Handle campaign completion

  ## How Multiple Phone Numbers Work
  
  When multiple phone numbers are selected:
  - Contacts are distributed across phone queues using round-robin
  - Each phone number gets its own Broadway Pipeline with 50 workers
  - Example: 100K contacts with 2 phones = 50K per phone, processed in parallel
  
  ## How Template Switching Works
  
  When Meta sends a "Template Paused" webhook:
  1. WebhookController receives the webhook
  2. QualityMonitor.switch_template_if_needed() is called
  3. QualityMonitor updates Redis key `campaign:{id}:active_template` to fallback
  4. All 50 workers per phone read from Redis before each message
  5. Next message uses the fallback template - instant switch!
  """

  require Logger

  alias TitanFlow.Campaigns
  alias TitanFlow.Campaigns.{Cache, Importer, Runner, Pipeline}
  alias TitanFlow.Templates
  alias TitanFlow.WhatsApp

  @doc """
  Start a campaign with full orchestration.
  
  ## Parameters
  - `campaign` - The campaign record
  - `phone_ids` - List of phone number database IDs (integers)
  - `template_ids` - List of template IDs (first is primary)
  - `csv_path` - Path to CSV file (optional)
  
  ## Returns
  - `{:ok, campaign}` - Campaign started successfully
  - `{:error, reason}` - Campaign failed to start
  """
  def start_campaign(campaign, phone_ids, template_ids, csv_path \\ nil) do
    Logger.info("Starting campaign #{campaign.id}: #{campaign.name}")
    
    try do
      do_start_campaign(campaign, phone_ids, template_ids, csv_path)
    rescue
      e ->
        error_msg = Exception.message(e)
        Logger.error("Campaign #{campaign.id} FAILED: #{error_msg}")
        Logger.error(Exception.format(:error, e, __STACKTRACE__))
        
        Campaigns.update_campaign(campaign, %{
          status: "error",
          error_message: error_msg
        })
        
        {:error, error_msg}
    end
  end

  defp do_start_campaign(campaign, phone_ids, template_ids, csv_path) do
    alias TitanFlow.Campaigns.BufferManager
    
    # Get phone number records
    phones = Enum.map(phone_ids, &WhatsApp.get_phone_number!/1)
    
    # Build phone_id -> template_ids mapping from senders_config
    phone_template_map = build_phone_template_map(campaign, phone_ids, template_ids)
    
    # Step 1: Import CSV if provided
    import_count = if csv_path do
      Logger.info("Campaign #{campaign.id}: Starting CSV import from #{csv_path}")
      
      # Check feature flag for fast importer
      use_fast = Application.get_env(:titan_flow, :features, [])[:use_fast_importer] || false
      
      import_result = if use_fast do
        Logger.info("Campaign #{campaign.id}: Using FastImporter (PostgreSQL COPY)")
        TitanFlow.Campaigns.FastImporter.import_csv(csv_path, campaign.id)
      else
        Logger.info("Campaign #{campaign.id}: Using legacy Importer")
        Importer.import_csv(csv_path, campaign.id)
      end
      
      case import_result do
        {:ok, count} ->
          Logger.info("Campaign #{campaign.id}: Imported #{count} contacts")
          Campaigns.update_campaign(campaign, %{total_records: count})
          count
        
        {:error, reason} ->
          Logger.error("Campaign #{campaign.id}: Import failed: #{inspect(reason)}")
          raise "CSV import failed: #{inspect(reason)}"
      end
    else
      0
    end
    
    # Step 1b: Apply deduplication (remove recently contacted)
    if import_count > 0 do
      alias TitanFlow.Campaigns.Sanitizer
      {:ok, skipped_count} = Sanitizer.apply_deduplication(campaign.id)
      
      if skipped_count > 0 do
        # Update total_records to reflect actual sendable contacts
        final_count = import_count - skipped_count
        Campaigns.update_campaign(campaign, %{total_records: final_count})
        Logger.info("Campaign #{campaign.id}: After dedup: #{final_count} contacts (#{skipped_count} removed)")
      end
    end
    
    # Step 2: Start BufferManagers (JIT queue strategy - NO bulk push)
    Logger.info("Campaign #{campaign.id}: Starting JIT BufferManagers for #{length(phones)} phones")
    
    total_phones = length(phones)
    phones
    |> Enum.with_index()
    |> Enum.each(fn {phone, phone_index} ->
      # Get template IDs for this specific phone
      phone_template_ids = Map.get(phone_template_map, phone.id, [])
      
      if Enum.empty?(phone_template_ids) do
        Logger.warning("Campaign #{campaign.id}: No templates configured for phone #{phone.id}")
      end
      
      # Start rate limiter for this phone if not already running
      case start_rate_limiter(phone) do
        {:ok, pid} ->
          Logger.info("Campaign #{campaign.id}: Started rate limiter #{inspect(pid)} for phone #{phone.phone_number_id}")
        :ok ->
          Logger.info("Campaign #{campaign.id}: Rate limiter already running for phone #{phone.phone_number_id}")
        {:error, reason} ->
          Logger.error("Campaign #{campaign.id}: Failed to start rate limiter for phone #{phone.phone_number_id}: #{inspect(reason)}")
      end
      
      # Start BufferManager (JIT queue feeder) with round-robin distribution
      case DynamicSupervisor.start_child(TitanFlow.BufferSupervisor, {
        BufferManager,
        campaign_id: campaign.id,
        phone_number_id: phone.phone_number_id,
        phone_index: phone_index,
        total_phones: total_phones
      }) do
        {:ok, pid} ->
          Logger.info("Campaign #{campaign.id}: BufferManager started #{inspect(pid)} for phone #{phone.phone_number_id} (index #{phone_index}/#{total_phones})")
        {:error, {:already_started, _}} ->
          Logger.info("Campaign #{campaign.id}: BufferManager already running for phone #{phone.phone_number_id}")
        {:error, reason} ->
          raise "Failed to start BufferManager: #{inspect(reason)}" 
      end
      
      # Start Broadway pipeline with phone-specific template IDs
      Logger.info("Campaign #{campaign.id}: Starting pipeline for phone #{phone.phone_number_id} with templates #{inspect(phone_template_ids)}")
      
      # Start under supervision with auto-restart on crash
      pipeline_spec = %{
        id: {:pipeline, phone.phone_number_id},
        start: {Pipeline, :start_link, [
          [
            phone_number_id: phone.phone_number_id,
            campaign_id: campaign.id,
            template_ids: phone_template_ids
          ]
        ]},
        restart: :permanent  # ALWAYS restart - prevents speed drops to 0
      }
      
      case DynamicSupervisor.start_child(TitanFlow.Campaigns.PipelineSupervisor, pipeline_spec) do
        {:ok, pid} ->
          Logger.info("Campaign #{campaign.id}: Pipeline started under supervision #{inspect(pid)}")
        {:error, {:already_started, pid}} ->
          Logger.info("Campaign #{campaign.id}: Pipeline already running #{inspect(pid)}")
        {:error, reason} ->
          Logger.error("Campaign #{campaign.id}: Failed to start pipeline: #{inspect(reason)}")
      end
    end)
    
    # Step 3: Update campaign status
    Campaigns.update_campaign(campaign, %{status: "running", started_at: NaiveDateTime.utc_now()})
    Logger.info("Campaign #{campaign.id}: Status set to running")
    
    {:ok, campaign}
  end

  
  @doc """
  Stop a running campaign.
  """
  def stop_campaign(campaign, phone_ids) do
    phones = Enum.map(phone_ids, &WhatsApp.get_phone_number!/1)
    
    Enum.each(phones, fn phone ->
      Pipeline.stop(phone.phone_number_id)
    end)
    
    Cache.clear_active_template(campaign.id)
    Campaigns.update_campaign(campaign, %{status: "stopped"})
    
    {:ok, campaign}
  end

  @doc """
  Pause a running campaign. Pipelines continue but no new messages are dispatched.
  """
  def pause_campaign(campaign_id) do
    campaign = Campaigns.get_campaign!(campaign_id)
    
    if campaign.status == "running" do
      # Set pause flag in Redis
      Redix.command(:redix, ["SET", "campaign:#{campaign_id}:paused", "1"])
      
      # Update DB status
      Campaigns.update_campaign(campaign, %{status: "paused"})
      Logger.info("Campaign #{campaign_id} paused")
      {:ok, :paused}
    else
      {:error, :not_running}
    end
  end

  @doc """
  Resume a paused campaign. Restarts Pipeline if not running.
  Also works for 'running' campaigns that lost their pipeline (e.g., after server restart).
  """
  def resume_campaign(campaign_id) do
    campaign = Campaigns.get_campaign!(campaign_id)
    
    cond do
      campaign.status == "paused" ->
        # Remove pause flag from Redis
        Redix.command(:redix, ["DEL", "campaign:#{campaign_id}:paused"])
        
        # Update DB status
        Campaigns.update_campaign(campaign, %{status: "running"})
        
        # Restart Pipeline for each phone if not already running
        restart_pipelines(campaign)
        
        Logger.info("Campaign #{campaign_id} resumed")
        {:ok, :resumed}
        
      campaign.status == "running" ->
        # Campaign shows running but might have lost its pipeline
        # Just restart pipelines without changing status
        restart_pipelines(campaign)
        Logger.info("Campaign #{campaign_id} pipelines restarted")
        {:ok, :restarted}
        
      true ->
        {:error, :invalid_status}
    end
  end


  defp restart_pipelines(campaign) do
    alias TitanFlow.Campaigns.BufferManager
    
    phones = Enum.map(campaign.phone_ids || [], &WhatsApp.get_phone_number!/1)
    
    # Build phone-to-template mapping
    phone_template_map = build_phone_template_map(
      campaign, 
      campaign.phone_ids || [],
      campaign.template_ids || []
    )
    
    total_phones = length(phones)
    phones
    |> Enum.with_index()
    |> Enum.each(fn {phone, phone_index} ->
      # Get template IDs for this specific phone
      phone_template_ids = Map.get(phone_template_map, phone.id, [])
      
      # Start RateLimiter if needed
      start_rate_limiter(phone)
      
      # Start BufferManager if not running (CRITICAL: feeds contacts to Pipeline!)
      buffer_name = {:via, Registry, {TitanFlow.BufferRegistry, {campaign.id, phone.phone_number_id}}}
      case GenServer.whereis(buffer_name) do
        nil ->
          case DynamicSupervisor.start_child(TitanFlow.BufferSupervisor, {
            BufferManager,
            campaign_id: campaign.id,
            phone_number_id: phone.phone_number_id,
            phone_index: phone_index,
            total_phones: total_phones
          }) do
            {:ok, pid} ->
              Logger.info("Campaign #{campaign.id}: Restarted BufferManager for phone #{phone.phone_number_id} - #{inspect(pid)}")
            {:error, {:already_started, _}} ->
              Logger.info("Campaign #{campaign.id}: BufferManager already running for phone #{phone.phone_number_id}")
            {:error, reason} ->
              Logger.error("Campaign #{campaign.id}: Failed to start BufferManager: #{inspect(reason)}")
          end
        pid ->
          Logger.info("Campaign #{campaign.id}: BufferManager already running for phone #{phone.phone_number_id} - #{inspect(pid)}")
      end
      
      # Check if Pipeline already exists
      case Registry.lookup(TitanFlow.Campaigns.PipelineRegistry, phone.phone_number_id) do
        [] ->
          # Start Pipeline with phone-specific template IDs under supervision
          pipeline_spec = %{
            id: {:pipeline, phone.phone_number_id},
            start: {Pipeline, :start_link, [
              [
                phone_number_id: phone.phone_number_id,
                campaign_id: campaign.id,
                template_ids: phone_template_ids
              ]
            ]},
            restart: :permanent  # ALWAYS restart
          }
          
          case DynamicSupervisor.start_child(TitanFlow.Campaigns.PipelineSupervisor, pipeline_spec) do
            {:ok, pid} ->
              Logger.info("Campaign #{campaign.id}: Restarted pipeline under supervision for phone #{phone.phone_number_id} - #{inspect(pid)}")
            {:error, reason} ->
              Logger.error("Campaign #{campaign.id}: Failed to restart pipeline: #{inspect(reason)}")
          end
        _ ->
          Logger.info("Campaign #{campaign.id}: Pipeline already running for phone #{phone.phone_number_id}")
      end
    end)
  end

  @doc """
  Check if a campaign is paused.
  """
  def is_paused?(campaign_id) do
    case Redix.command(:redix, ["GET", "campaign:#{campaign_id}:paused"]) do
      {:ok, "1"} -> true
      _ -> false
    end
  end
  
  @doc """
  Retry all failed contacts for a completed campaign.
  
  1. Syncs templates from Meta (get fresh status)
  2. Clears all Redis exhausted/failed state
  3. Identifies phones with APPROVED templates
  4. Restarts campaign with only those phones
  5. BufferManager will fetch failed contacts from DB
  """
  def retry_failed_contacts(campaign_id) do
    campaign = Campaigns.get_campaign!(campaign_id)
    
    Logger.info("Retrying failed contacts for campaign #{campaign_id}")
    
    # Step 1: Sync templates from Meta for each phone
    for config <- campaign.senders_config || [] do
      phone_id = config["phone_id"]
      try do
        TitanFlow.WhatsApp.sync_templates(phone_id)
        Logger.info("Synced templates for phone #{phone_id}")
      rescue
        e -> Logger.warning("Failed to sync templates for phone #{phone_id}: #{inspect(e)}")
      end
    end
    
    # Step 2: Clear ALL campaign Redis state (exhausted phones, failed templates)
    {:ok, keys} = Redix.command(:redix, ["KEYS", "campaign:#{campaign_id}:*"])
    for key <- keys || [] do
      Redix.command(:redix, ["DEL", key])
    end
    Logger.info("Cleared #{length(keys || [])} Redis keys for campaign #{campaign_id}")
    
    # Step 3: Get phones with APPROVED templates only
    valid_phone_ids = for config <- campaign.senders_config || [], reduce: [] do
      acc ->
        phone_id = config["phone_id"]
        template_ids = config["template_ids"] || []
        
        # Check which templates are APPROVED
        approved_templates = Enum.filter(template_ids, fn tid ->
          try do
            template = TitanFlow.Templates.get_template!(tid)
            template.status == "APPROVED"
          rescue
            _ -> false
          end
        end)
        
        if length(approved_templates) > 0 do
          [phone_id | acc]
        else
          Logger.warning("Phone #{phone_id} has no APPROVED templates, skipping")
          acc
        end
    end
    
    if length(valid_phone_ids) == 0 do
      Logger.error("No phones have APPROVED templates for campaign #{campaign_id}")
      Campaigns.update_campaign(campaign, %{
        status: "paused",
        error_message: "No phones have APPROVED templates. Please sync templates first."
      })
      {:error, :no_valid_phones}
    else
      # Step 4: Update campaign status to running
      Campaigns.update_campaign(campaign, %{
        status: "running",
        error_message: nil,
        completed_at: nil
      })
      
      # Step 5: Start pipelines for valid phones only
      # Use existing restart_pipelines logic but filter to valid phones
      phones = Enum.map(valid_phone_ids, &WhatsApp.get_phone_number!/1)
      phone_template_map = build_phone_template_map(campaign, valid_phone_ids, campaign.template_ids || [])
      
      total_phones = length(phones)
      phones
      |> Enum.with_index()
      |> Enum.each(fn {phone, phone_index} ->
        phone_template_ids = Map.get(phone_template_map, phone.id, [])
        
        # Start RateLimiter
        start_rate_limiter(phone)
        
        # Start BufferManager (will fetch failed/unsent contacts)
        buffer_name = {:via, Registry, {TitanFlow.BufferRegistry, {campaign.id, phone.phone_number_id}}}
        case GenServer.whereis(buffer_name) do
          nil ->
            DynamicSupervisor.start_child(TitanFlow.BufferSupervisor, {
              TitanFlow.Campaigns.BufferManager,
              campaign_id: campaign.id,
              phone_number_id: phone.phone_number_id,
              phone_index: phone_index,
              total_phones: total_phones
            })
          _ -> :ok
        end
        
        # Start Pipeline
        case Registry.lookup(TitanFlow.Campaigns.PipelineRegistry, phone.phone_number_id) do
          [] ->
            pipeline_spec = %{
              id: {:pipeline, phone.phone_number_id},
              start: {Pipeline, :start_link, [[
                phone_number_id: phone.phone_number_id,
                campaign_id: campaign.id,
                template_ids: phone_template_ids
              ]]},
              restart: :permanent
            }
            DynamicSupervisor.start_child(TitanFlow.Campaigns.PipelineSupervisor, pipeline_spec)
          _ -> :ok
        end
      end)
      
      Logger.info("Campaign #{campaign_id} retry started with #{length(valid_phone_ids)} phones")
      {:ok, :retry_started}
    end
  end
  
  defp build_phone_template_map(campaign, phone_ids, template_ids) do
    # Try to use senders_config (new format)
    if campaign.senders_config && length(campaign.senders_config) > 0 do
      # Build map from senders_config: %{phone_id => [template_id1, template_id2]}
      campaign.senders_config
      |> Enum.map(fn config ->
        phone_id = config["phone_id"]
        tmpl_ids = config["template_ids"] || []
        {phone_id, tmpl_ids}
      end)
      |> Map.new()
    else
      # Legacy fallback: All phones get all templates
      Logger.warning("Campaign #{campaign.id}: Using legacy phone_ids/template_ids (no senders_config)")
      phone_ids
      |> Enum.map(fn phone_id -> {phone_id, template_ids} end)
      |> Map.new()
    end
  end
  
  defp start_rate_limiter(phone) do
    # Check if already started
    case Registry.lookup(TitanFlow.WhatsApp.RateLimiterRegistry, phone.phone_number_id) do
      [] ->
        # Start under the DynamicSupervisor
        DynamicSupervisor.start_child(
          TitanFlow.PhoneSupervisor,
          {TitanFlow.WhatsApp.RateLimiter, 
           phone_number_id: phone.phone_number_id,
           access_token: phone.access_token}
        )
      _ ->
        :ok
    end
  end
end
