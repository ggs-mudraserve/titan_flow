defmodule TitanFlow.Campaigns.Orchestrator do
  @moduledoc """
  Orchestrates the full campaign execution flow:
  1. Import CSV contacts
  2. Start BufferManagers (JIT queue filling from DB)
  3. Start Broadway Pipelines for each phone number
  4. Handle campaign completion

  ## How Multiple Phone Numbers Work

  When multiple phone numbers are selected:
  - Contacts are distributed across phone queues using round-robin
  - Each phone number gets its own Broadway Pipeline with 50 workers
  - Example: 100K contacts with 2 phones = 50K per phone, processed in parallel

  ## How Template Fallback Works

  1. Each phone has an ordered list of template IDs from senders_config
  2. Pipeline tries templates sequentially per message
  3. If a template is marked paused in Redis, it's skipped immediately
  4. Templates that fail with specific error codes are marked exhausted for that phone
  5. If all templates fail for a phone, it's marked exhausted
  """

  require Logger

  @preflight_test_numbers ["919555555611", "919891411411"]
  @preflight_wait_ms 5_000
  @preflight_var1 "Nitin"
  @preflight_var2 "test"

  alias TitanFlow.Campaigns
  alias TitanFlow.Campaigns.{Cache, Importer, Pipeline}
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
    phone_mps_map = build_phone_mps_map(campaign, phone_ids)

    # Step 1: Import CSV if provided
    import_count =
      if csv_path do
        Logger.info("Campaign #{campaign.id}: Starting CSV import from #{csv_path}")

        # Check feature flag for fast importer
        use_fast = Application.get_env(:titan_flow, :features, [])[:use_fast_importer] || false

        import_result =
          if use_fast do
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

        Logger.info(
          "Campaign #{campaign.id}: After dedup: #{final_count} contacts (#{skipped_count} removed)"
        )
      end
    end

    # Step 1c: Pre-flight phone verification
    # Send 2 test messages per phone to dedicated numbers before weighted distribution
    Logger.info(
      "Campaign #{campaign.id}: Running pre-flight verification for #{length(phones)} phones"
    )

    verified_phones = verify_phones(campaign, phones, phone_template_map)

    if Enum.empty?(verified_phones) do
      raise "Pre-flight failed: No phones passed verification. Check phone billing/template status."
    end

    if length(verified_phones) < length(phones) do
      failed_phones = phones -- verified_phones

      Logger.warning(
        "Campaign #{campaign.id}: #{length(failed_phones)} phones failed pre-flight: #{inspect(Enum.map(failed_phones, & &1.id))}"
      )
    end

    # Step 2: Build weighted phone distribution based on MPS
    weighted_map = build_weighted_phone_map(verified_phones, phone_mps_map)

    # Step 3: Start BufferManagers with weighted distribution
    Logger.info(
      "Campaign #{campaign.id}: Starting BufferManagers with weighted distribution for #{length(verified_phones)} phones"
    )

    verified_phones
    |> Enum.each(fn phone ->
      # Get template IDs for this specific phone
      phone_template_ids = Map.get(phone_template_map, phone.id, [])

      if Enum.empty?(phone_template_ids) do
        Logger.warning("Campaign #{campaign.id}: No templates configured for phone #{phone.id}")
      end

      # Start rate limiter for this phone if not already running
      phone_mps = Map.get(phone_mps_map, phone.id, 80)

      case start_rate_limiter(phone, phone_mps) do
        {:ok, pid} ->
          Logger.info(
            "Campaign #{campaign.id}: Started rate limiter #{inspect(pid)} for phone #{phone.phone_number_id}"
          )

        :ok ->
          Logger.info(
            "Campaign #{campaign.id}: Rate limiter already running for phone #{phone.phone_number_id}"
          )

        {:error, reason} ->
          Logger.error(
            "Campaign #{campaign.id}: Failed to start rate limiter for phone #{phone.phone_number_id}: #{inspect(reason)}"
          )
      end

      # Get weighted indices for this phone
      weighted_indices = Map.get(weighted_map.phone_indices, phone.phone_number_id, [0])
      total_slots = weighted_map.total_slots

      # Start BufferManager with weighted distribution
      case DynamicSupervisor.start_child(TitanFlow.BufferSupervisor, {
             BufferManager,
             campaign_id: campaign.id,
             phone_number_id: phone.phone_number_id,
             weighted_indices: weighted_indices,
             total_slots: total_slots
           }) do
        {:ok, pid} ->
          Logger.info(
            "Campaign #{campaign.id}: BufferManager started #{inspect(pid)} for phone #{phone.phone_number_id} (indices #{inspect(weighted_indices)}/#{total_slots})"
          )

        {:error, {:already_started, _}} ->
          Logger.info(
            "Campaign #{campaign.id}: BufferManager already running for phone #{phone.phone_number_id}"
          )

        {:error, reason} ->
          raise "Failed to start BufferManager: #{inspect(reason)}"
      end

      # Start Broadway pipeline with phone-specific template IDs
      Logger.info(
        "Campaign #{campaign.id}: Starting pipeline for phone #{phone.phone_number_id} with templates #{inspect(phone_template_ids)}"
      )

      # Start under supervision with auto-restart on crash
      pipeline_spec = %{
        id: {:pipeline, phone.phone_number_id},
        start:
          {Pipeline, :start_link,
           [
             [
               phone_number_id: phone.phone_number_id,
               campaign_id: campaign.id,
               template_ids: phone_template_ids
             ]
           ]},
        # ALWAYS restart - prevents speed drops to 0
        restart: :permanent
      }

      case DynamicSupervisor.start_child(TitanFlow.Campaigns.PipelineSupervisor, pipeline_spec) do
        {:ok, pid} ->
          Logger.info(
            "Campaign #{campaign.id}: Pipeline started under supervision #{inspect(pid)}"
          )

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

    # Bug Fix #2: Terminate children from supervisor to prevent auto-restart
    Enum.each(phones, fn phone ->
      stop_pipeline_for_phone(phone.phone_number_id)
      stop_buffer_manager_for_phone(campaign.id, phone.phone_number_id)
    end)

    Cache.clear_active_template(campaign.id)
    Campaigns.update_campaign(campaign, %{status: "stopped"})

    {:ok, campaign}
  end

  @doc """
  Stop all pipelines for a campaign (called on completion).
  """
  def stop_all_pipelines(campaign_id) do
    campaign = Campaigns.get_campaign!(campaign_id)

    # Get all phone_ids for this campaign
    phone_ids =
      case campaign.senders_config do
        nil ->
          campaign.phone_ids || []

        config when is_list(config) ->
          Enum.map(config, fn c -> c["phone_id"] end)

        _ ->
          campaign.phone_ids || []
      end

    phones = Enum.map(phone_ids, &WhatsApp.get_phone_number!/1)

    Enum.each(phones, fn phone ->
      stop_pipeline_for_phone(phone.phone_number_id)
      stop_buffer_manager_for_phone(campaign_id, phone.phone_number_id)
    end)

    Logger.info("Campaign #{campaign_id}: All pipelines and buffer managers stopped")
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

        # Force restart pipelines to clear any stalled workers
        restart_pipelines(campaign, force: true)

        Logger.info("Campaign #{campaign_id} resumed")
        {:ok, :resumed}

      campaign.status == "running" ->
        # Campaign shows running but might have lost its pipeline
        # Force restart pipelines to clear any stalled workers
        restart_pipelines(campaign, force: true)
        Logger.info("Campaign #{campaign_id} pipelines restarted")
        {:ok, :restarted}

      true ->
        {:error, :invalid_status}
    end
  end

  defp restart_pipelines(campaign, opts) do
    alias TitanFlow.Campaigns.BufferManager

    force_restart = Keyword.get(opts, :force, false)

    phone_ids =
      case campaign.senders_config do
        config when is_list(config) and length(config) > 0 ->
          config
          |> Enum.map(& &1["phone_id"])
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()

        _ ->
          campaign.phone_ids || []
      end

    phones = Enum.map(phone_ids, &WhatsApp.get_phone_number!/1)

    # Build phone-to-template mapping
    phone_template_map =
      build_phone_template_map(
        campaign,
        phone_ids,
        campaign.template_ids || []
      )

    phone_mps_map = build_phone_mps_map(campaign, phone_ids)

    if Enum.empty?(phones) do
      Logger.warning("Campaign #{campaign.id}: No phones to restart")
      :ok
    else
      weighted_map = build_weighted_phone_map(phones, phone_mps_map)

      phones
      |> Enum.each(fn phone ->
        # Get template IDs for this specific phone
        phone_template_ids = Map.get(phone_template_map, phone.id, [])

        # Start RateLimiter if needed
        phone_mps = Map.get(phone_mps_map, phone.id, 80)
        start_rate_limiter(phone, phone_mps)

        if force_restart do
          stop_pipeline_for_phone(phone.phone_number_id)
        end

        weighted_indices = Map.get(weighted_map.phone_indices, phone.phone_number_id, [0])
        total_slots = weighted_map.total_slots

        # Start BufferManager if not running (CRITICAL: feeds contacts to Pipeline!)
        buffer_name =
          {:via, Registry, {TitanFlow.BufferRegistry, {campaign.id, phone.phone_number_id}}}

        case GenServer.whereis(buffer_name) do
          nil ->
            case DynamicSupervisor.start_child(TitanFlow.BufferSupervisor, {
                   BufferManager,
                   campaign_id: campaign.id,
                   phone_number_id: phone.phone_number_id,
                   weighted_indices: weighted_indices,
                   total_slots: total_slots
                 }) do
              {:ok, pid} ->
                Logger.info(
                  "Campaign #{campaign.id}: Restarted BufferManager for phone #{phone.phone_number_id} - #{inspect(pid)}"
                )

              {:error, {:already_started, _}} ->
                Logger.info(
                  "Campaign #{campaign.id}: BufferManager already running for phone #{phone.phone_number_id}"
                )

              {:error, reason} ->
                Logger.error(
                  "Campaign #{campaign.id}: Failed to start BufferManager: #{inspect(reason)}"
                )
            end

          pid ->
            Logger.info(
              "Campaign #{campaign.id}: BufferManager already running for phone #{phone.phone_number_id} - #{inspect(pid)}"
            )
        end

        # Check if Pipeline already exists
        case Registry.lookup(TitanFlow.Campaigns.PipelineRegistry, phone.phone_number_id) do
          [] ->
            # Start Pipeline with phone-specific template IDs under supervision
            pipeline_spec = %{
              id: {:pipeline, phone.phone_number_id},
              start:
                {Pipeline, :start_link,
                 [
                   [
                     phone_number_id: phone.phone_number_id,
                     campaign_id: campaign.id,
                     template_ids: phone_template_ids
                   ]
                 ]},
              # ALWAYS restart
              restart: :permanent
            }

            case DynamicSupervisor.start_child(
                   TitanFlow.Campaigns.PipelineSupervisor,
                   pipeline_spec
                 ) do
              {:ok, pid} ->
                Logger.info(
                  "Campaign #{campaign.id}: Restarted pipeline under supervision for phone #{phone.phone_number_id} - #{inspect(pid)}"
                )

              {:error, reason} ->
                Logger.error(
                  "Campaign #{campaign.id}: Failed to restart pipeline: #{inspect(reason)}"
                )
            end

          _ ->
            Logger.info(
              "Campaign #{campaign.id}: Pipeline already running for phone #{phone.phone_number_id}"
            )
        end
      end)
    end
  end

  @doc """
  Force restart pipelines for a campaign without changing its status.
  """
  def force_restart_pipelines(campaign_id) do
    campaign = Campaigns.get_campaign!(campaign_id)
    restart_pipelines(campaign, force: true)
    Logger.warning("Campaign #{campaign_id}: Pipelines force-restarted")
    :ok
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

    # Mark retry mode to prevent premature completion based on historical counts
    _ =
      Redix.command(:redix, [
        "SET",
        "campaign:#{campaign_id}:retry_mode",
        "1",
        "EX",
        86_400
      ])

    # Step 3: Get phones with APPROVED templates only (and map approved templates per phone)
    {valid_phone_ids, approved_templates_by_phone} =
      (campaign.senders_config || [])
      |> Enum.reduce({[], %{}}, fn config, {ids_acc, map_acc} ->
        phone_id = config["phone_id"]
        template_ids = config["template_ids"] || []

        approved_templates =
          Enum.filter(template_ids, fn tid ->
            try do
              template = TitanFlow.Templates.get_template!(tid)
              template.status == "APPROVED"
            rescue
              _ -> false
            end
          end)

        skipped_count = length(template_ids) - length(approved_templates)

        if length(approved_templates) > 0 do
          if skipped_count > 0 do
            Logger.info(
              "Retry: Phone #{phone_id} using approved templates #{inspect(approved_templates)} (skipped #{skipped_count} non-approved/missing)"
            )
          else
            Logger.info(
              "Retry: Phone #{phone_id} using approved templates #{inspect(approved_templates)}"
            )
          end

          {[phone_id | ids_acc], Map.put(map_acc, phone_id, approved_templates)}
        else
          Logger.warning("Retry: Phone #{phone_id} has no APPROVED templates, skipping")
          {ids_acc, map_acc}
        end
      end)

    valid_phone_ids = Enum.reverse(valid_phone_ids)

    if length(valid_phone_ids) == 0 do
      Logger.error("No phones have APPROVED templates for campaign #{campaign_id}")

      Campaigns.update_campaign(campaign, %{
        status: "paused",
        error_message: "No phones have APPROVED templates. Please sync templates first."
      })

      {:error, :no_valid_phones}
    else
      # Step 4: Start pipelines for valid phones only
      # Use existing restart_pipelines logic but filter to valid phones
      phones = Enum.map(valid_phone_ids, &WhatsApp.get_phone_number!/1)

      phone_template_map = approved_templates_by_phone

      phone_mps_map = build_phone_mps_map(campaign, valid_phone_ids)

      weighted_map = build_weighted_phone_map(phones, phone_mps_map)

      phones
      |> Enum.each(fn phone ->
        phone_template_ids = Map.get(phone_template_map, phone.id, [])

        # Start RateLimiter
        phone_mps = Map.get(phone_mps_map, phone.id, 80)
        start_rate_limiter(phone, phone_mps)

        weighted_indices = Map.get(weighted_map.phone_indices, phone.phone_number_id, [0])
        total_slots = weighted_map.total_slots

        # Start BufferManager in RETRY MODE (will fetch failed/unsent contacts)
        buffer_name =
          {:via, Registry, {TitanFlow.BufferRegistry, {campaign.id, phone.phone_number_id}}}

        case GenServer.whereis(buffer_name) do
          nil ->
            DynamicSupervisor.start_child(TitanFlow.BufferSupervisor, {
              TitanFlow.Campaigns.BufferManager,
              # Enable retry mode to fetch failed contacts
              campaign_id: campaign.id,
              phone_number_id: phone.phone_number_id,
              weighted_indices: weighted_indices,
              total_slots: total_slots,
              retry_mode: true
            })

          _pid ->
            # Restart to ensure retry_mode is enabled and cursor resets
            stop_buffer_manager_for_phone(campaign.id, phone.phone_number_id)

            DynamicSupervisor.start_child(TitanFlow.BufferSupervisor, {
              TitanFlow.Campaigns.BufferManager,
              campaign_id: campaign.id,
              phone_number_id: phone.phone_number_id,
              weighted_indices: weighted_indices,
              total_slots: total_slots,
              retry_mode: true
            })
        end

        # Start Pipeline (restart if an old pipeline is already registered for this phone)
        case Registry.lookup(TitanFlow.Campaigns.PipelineRegistry, phone.phone_number_id) do
          [] ->
            pipeline_spec = %{
              id: {:pipeline, phone.phone_number_id},
              start:
                {Pipeline, :start_link,
                 [
                   [
                     phone_number_id: phone.phone_number_id,
                     campaign_id: campaign.id,
                     template_ids: phone_template_ids
                   ]
                 ]},
              restart: :permanent
            }

            DynamicSupervisor.start_child(TitanFlow.Campaigns.PipelineSupervisor, pipeline_spec)

          _ ->
            stop_pipeline_for_phone(phone.phone_number_id)

            pipeline_spec = %{
              id: {:pipeline, phone.phone_number_id},
              start:
                {Pipeline, :start_link,
                 [
                   [
                     phone_number_id: phone.phone_number_id,
                     campaign_id: campaign.id,
                     template_ids: phone_template_ids
                   ]
                 ]},
              restart: :permanent
            }

            DynamicSupervisor.start_child(TitanFlow.Campaigns.PipelineSupervisor, pipeline_spec)
        end
      end)

      Logger.info("Campaign #{campaign_id} retry started with #{length(valid_phone_ids)} phones")

      # Step 5: Update campaign status to running (after pipelines/buffers started)
      # IMPORTANT: Reset failed_count so count-based completion doesn't trigger immediately
      # The failed count will be rebuilt as retried messages are processed
      Campaigns.update_campaign(campaign, %{
        status: "running",
        error_message: nil,
        completed_at: nil,
        # Reset for retry
        failed_count: 0
      })

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
      Logger.warning(
        "Campaign #{campaign.id}: Using legacy phone_ids/template_ids (no senders_config)"
      )

      phone_ids
      |> Enum.map(fn phone_id -> {phone_id, template_ids} end)
      |> Map.new()
    end
  end

  defp build_phone_mps_map(campaign, phone_ids) do
    if campaign.senders_config && length(campaign.senders_config) > 0 do
      campaign.senders_config
      |> Enum.map(fn config ->
        phone_id = config["phone_id"]
        mps = clamp_mps(config["mps"] || 80)
        {phone_id, mps}
      end)
      |> Map.new()
    else
      phone_ids
      |> Enum.map(fn phone_id -> {phone_id, 80} end)
      |> Map.new()
    end
  end

  defp clamp_mps(val) when is_integer(val) do
    val
    |> max(10)
    |> min(500)
  end

  defp clamp_mps(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> clamp_mps(n)
      :error -> 80
    end
  end

  defp clamp_mps(_), do: 80

  defp start_rate_limiter(phone, max_mps) do
    # Check if already started
    case Registry.lookup(TitanFlow.WhatsApp.RateLimiterRegistry, phone.phone_number_id) do
      [] ->
        # Start under the DynamicSupervisor with phone's configured MPS
        DynamicSupervisor.start_child(
          TitanFlow.PhoneSupervisor,
          {TitanFlow.WhatsApp.RateLimiter,
           phone_number_id: phone.phone_number_id,
           access_token: phone.access_token,
           max_mps: clamp_mps(max_mps)}
        )

      _ ->
        TitanFlow.WhatsApp.RateLimiter.set_mps(phone.phone_number_id, clamp_mps(max_mps))
        :ok
    end
  end

  # Bug Fix #2: Helper functions to terminate children from supervisor
  defp stop_pipeline_for_phone(phone_number_id) do
    case Registry.lookup(TitanFlow.Campaigns.PipelineRegistry, phone_number_id) do
      [{pid, _}] ->
        # Terminate the child from supervisor (prevents auto-restart)
        DynamicSupervisor.terminate_child(TitanFlow.Campaigns.PipelineSupervisor, pid)
        Logger.info("Pipeline for phone #{phone_number_id} terminated")

      [] ->
        :ok
    end
  end

  defp stop_buffer_manager_for_phone(campaign_id, phone_number_id) do
    case Registry.lookup(TitanFlow.BufferRegistry, {campaign_id, phone_number_id}) do
      [{pid, _}] ->
        # Terminate the child from supervisor
        DynamicSupervisor.terminate_child(TitanFlow.BufferSupervisor, pid)

        Logger.info(
          "BufferManager for campaign #{campaign_id}, phone #{phone_number_id} terminated"
        )

      [] ->
        :ok
    end
  end

  # Pre-flight phone verification with WEBHOOK WAIT
  # Sends 2 test messages per phone to dedicated numbers, waits for webhook, checks status in DB
  defp verify_phones(campaign, phones, phone_template_map) do
    media_url = get_preflight_media_url(campaign.id)
    Logger.info("Pre-flight: Sending test messages to #{length(phones)} phones...")

    # Step 1: Send test messages to each phone and collect {phone, message_ids}
    test_results =
      phones
      |> Task.async_stream(
        fn phone ->
          send_preflight_tests(campaign, phone, phone_template_map, media_url)
        end,
        timeout: 30_000,
        max_concurrency: length(phones)
      )
      |> Enum.reduce([], fn result, acc ->
        case result do
          {:ok, {:ok, phone, message_ids}} ->
            [{phone, message_ids} | acc]

          {:ok, {:error, phone, reason}} ->
            Logger.warning("Pre-flight FAILED immediately for phone #{phone.id}: #{reason}")
            acc

          {:exit, reason} ->
            Logger.error("Pre-flight task crashed: #{inspect(reason)}")
            acc
        end
      end)

    if Enum.empty?(test_results) do
      Logger.error("Pre-flight: All phones failed initial test send")
      []
    else
      Logger.info(
        "Pre-flight: #{length(test_results)} phones sent test messages, waiting for webhooks..."
      )

      # Step 2: Wait for webhooks to arrive and be processed
      Process.sleep(@preflight_wait_ms)

      # Step 3: Check each message status in DB for failures
      test_results
      |> Enum.filter(fn {phone, message_ids} ->
        passed =
          Enum.all?(message_ids, fn message_id ->
            case check_test_message_status(message_id) do
              :ok ->
                true

              {:error, reason} ->
                Logger.warning("Pre-flight FAILED (webhook) for phone #{phone.id}: #{reason}")
                false
            end
          end)

        if passed do
          Logger.info("Pre-flight PASSED for phone #{phone.id} (#{phone.phone_number_id})")
        end

        passed
      end)
      |> Enum.map(fn {phone, _message_ids} -> phone end)
    end
  end

  defp get_preflight_media_url(campaign_id) do
    import Ecto.Query
    alias TitanFlow.Repo

    query =
      from c in "contacts",
        where: c.campaign_id == ^campaign_id,
        where: c.is_blacklisted == false,
        where: fragment("COALESCE(?->>'media_url','') <> ''", c.variables),
        order_by: [asc: c.id],
        limit: 1,
        select: fragment("?->>'media_url'", c.variables)

    Repo.one(query)
  end

  defp preflight_variables(media_url) do
    variables = %{
      "var1" => @preflight_var1,
      "var2" => @preflight_var2
    }

    if media_url && media_url != "" do
      Map.put(variables, "media_url", media_url)
    else
      variables
    end
  end

  # Send test messages to dedicated preflight numbers and return the message_ids
  defp send_preflight_tests(campaign, phone, phone_template_map, media_url) do
    template_ids = Map.get(phone_template_map, phone.id, [])

    if Enum.empty?(template_ids) do
      {:error, phone, "No templates configured"}
    else
      template_id = List.first(template_ids)
      template = TitanFlow.Templates.get_template!(template_id)

      variables = preflight_variables(media_url)

      results =
        Enum.reduce_while(@preflight_test_numbers, {:ok, []}, fn test_number, {:ok, acc} ->
          test_contact = %{phone: test_number, variables: variables}

          case send_test_message(phone, template, test_contact) do
            {:ok, message_id} ->
              # Record the test message in message_logs so webhook can find it
              record_preflight_message(campaign.id, message_id, test_number, phone, template)
              {:cont, {:ok, [message_id | acc]}}

            {:error, error_code, error_msg} ->
              {:halt,
               {:error, phone, "API error (#{error_code}) to #{test_number}: #{error_msg}"}}
          end
        end)

      case results do
        {:ok, message_ids} -> {:ok, phone, Enum.reverse(message_ids)}
        {:error, _phone, _reason} = error -> error
      end
    end
  end

  # Check if test message was marked as failed by webhook
  # No message to check (no contacts)
  defp check_test_message_status(nil), do: :ok

  defp check_test_message_status(message_id) do
    import Ecto.Query
    alias TitanFlow.Repo

    case Repo.one(
           from m in "message_logs",
             where: m.meta_message_id == ^message_id,
             select: %{status: m.status, error_code: m.error_code}
         ) do
      nil ->
        Logger.warning("Pre-flight: Message #{message_id} not found in logs, assuming OK")
        :ok

      %{status: "failed", error_code: error_code} when error_code in ["131042", "131045"] ->
        {:error, "Payment error detected via webhook (#{error_code})"}

      %{status: "failed", error_code: error_code} ->
        # Other failures might be transient
        Logger.warning("Pre-flight: Message failed with #{error_code}, treating as phone issue")
        {:error, "Webhook failure (#{error_code})"}

      _other ->
        # sent, delivered, read - all good
        :ok
    end
  end

  # Record preflight test message so webhook can update its status
  defp record_preflight_message(_campaign_id, message_id, recipient_phone, phone, template) do
    alias TitanFlow.Campaigns.MessageLog
    alias TitanFlow.Repo

    attrs = %{
      meta_message_id: message_id,
      campaign_id: nil,
      contact_id: nil,
      recipient_phone: recipient_phone,
      template_name: template.name,
      phone_number_id: phone.phone_number_id,
      status: "sent",
      sent_at: DateTime.utc_now()
    }

    changeset = MessageLog.changeset(%MessageLog{}, attrs)

    case Repo.insert(changeset, on_conflict: :nothing, conflict_target: :meta_message_id) do
      {:ok, _log} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Pre-flight: Failed to insert message log #{message_id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp send_test_message(phone, template, contact) do
    alias TitanFlow.WhatsApp.Client

    # Build template payload
    components = build_template_components(template, contact)

    # Build credentials map for the correct function signature
    credentials = %{
      access_token: phone.access_token,
      phone_number_id: phone.phone_number_id
    }

    case Client.send_template(
           contact.phone,
           template.name,
           template.language,
           components,
           credentials
         ) do
      {:ok, %{"messages" => [%{"id" => message_id}]}, _headers} ->
        # Pre-flight success - phone works
        {:ok, message_id}

      {:error, {:api_error, _status, %{"error" => %{"code" => code, "message" => msg}}, _headers}} ->
        {:error, code, msg}

      {:error, reason} ->
        {:error, 0, inspect(reason)}
    end
  end

  defp build_template_components(_template, contact) do
    # Mirror Pipeline component builder for consistent payloads
    variables = contact.variables || %{}

    components = []

    media_url = variables["media_url"]

    components =
      if media_url && media_url != "" do
        header_component = %{
          "type" => "header",
          "parameters" => [
            %{"type" => "video", "video" => %{"link" => media_url}}
          ]
        }

        [header_component | components]
      else
        components
      end

    body_params =
      variables
      |> Enum.filter(fn {key, _} -> String.starts_with?(key, "var") end)
      |> Enum.sort_by(fn {key, _} -> key end)
      |> Enum.map(fn {_key, value} ->
        %{"type" => "text", "text" => to_string(value)}
      end)

    components =
      if Enum.empty?(body_params) do
        components
      else
        [%{"type" => "body", "parameters" => body_params} | components]
      end

    Enum.reverse(components)
  end

  @doc """
  Build weighted phone map for round-robin distribution based on MPS.

  Given phones with MPS [40, 20, 20], returns:
  - GCD: 20
  - Weights: [2, 1, 1] 
  - Total slots: 4
  - Indices: %{phone1 => [0, 1], phone2 => [2], phone3 => [3]}

  This ensures phone1 (40 MPS) gets 50% of contacts, phones 2&3 get 25% each.
  """
  def build_weighted_phone_map(phones, phone_mps_map) do
    # Get MPS for each phone (default 80 if not specified)
    mps_values =
      Enum.map(phones, fn phone ->
        Map.get(phone_mps_map, phone.id, 80)
      end)

    # Calculate GCD of all MPS values
    gcd = Enum.reduce(mps_values, hd(mps_values), &Integer.gcd/2)

    # Calculate weights (MPS / GCD)
    weights = Enum.map(mps_values, fn mps -> div(mps, gcd) end)
    total_slots = Enum.sum(weights)

    # Assign indices to each phone
    {phone_indices, _} =
      Enum.zip(phones, weights)
      |> Enum.reduce({%{}, 0}, fn {phone, weight}, {acc, current_index} ->
        indices = Enum.to_list(current_index..(current_index + weight - 1))
        {Map.put(acc, phone.phone_number_id, indices), current_index + weight}
      end)

    Logger.info(
      "Weighted distribution: GCD=#{gcd}, weights=#{inspect(weights)}, total_slots=#{total_slots}"
    )

    Enum.zip(phones, weights)
    |> Enum.each(fn {phone, weight} ->
      Logger.info(
        "  Phone #{phone.phone_number_id}: weight=#{weight}, indices=#{inspect(Map.get(phone_indices, phone.phone_number_id))}"
      )
    end)

    %{
      phone_indices: phone_indices,
      total_slots: total_slots
    }
  end
end
