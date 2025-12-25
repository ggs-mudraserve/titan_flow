defmodule TitanFlow.Campaigns.Pipeline do
  @moduledoc """
  Broadway pipeline for processing messages from Redis queues.

  Uses Broadway with OffBroadway.Redis.Producer to consume messages
  from per-phone-number queues and dispatch them through the rate limiter.

  ## Architecture
  - One pipeline instance per phone_number_id
  - 50 concurrent processors
  - Automatic retry with backoff for rate-limited messages
  - **Late-Binding Templates**: Fetches template from Redis cache before each message,
    allowing instant template switches without stopping the campaign.
  """

  use Broadway

  alias Broadway.Message
  alias TitanFlow.WhatsApp.RateLimiter
  alias TitanFlow.Campaigns.{Orchestrator, MessageTracking}

  @retry_delay_ms 100
  @max_retries 5

  @doc """
  Start a Broadway pipeline for a specific phone number's queue.

  ## Options
  - `:phone_number_id` - Required. The phone number ID to process
  - `:campaign_id` - Required. Campaign ID for late-binding template lookup
  - `:template_name` - Required. Default template (used if Redis cache miss)
  - `:language_code` - Required. Default language code
  - `:redis_config` - Optional. Redis connection config (uses app config by default)
  """
  def start_link(opts) do
    phone_number_id = Keyword.fetch!(opts, :phone_number_id)
    campaign_id = Keyword.fetch!(opts, :campaign_id)
    template_ids = Keyword.get(opts, :template_ids, [])

    redix_config =
      Keyword.get_lazy(opts, :redis_config, fn ->
        Application.get_env(:titan_flow, :redix)
      end)

    queue_name = "queue:sending:#{campaign_id}:#{phone_number_id}"

    # Load templates into cache once at startup (eliminates DB queries during campaign)
    templates_cache = load_templates_into_cache(template_ids)
    require Logger

    Logger.info(
      "Pipeline: Loaded #{map_size(templates_cache)} templates into cache for phone #{phone_number_id}"
    )

    Broadway.start_link(__MODULE__,
      name: via_tuple(phone_number_id),
      producer: [
        module: {
          TitanFlow.Campaigns.RedisProducer,
          redis_config: redix_config, list_name: queue_name, batch_size: 200
        },
        concurrency: 1
      ],
      processors: [
        default: [
          # High Performance: 50 workers per phone. Finch pool handles network, Supavisor handles DB.
          concurrency: 50
        ]
      ],
      context: %{
        phone_number_id: phone_number_id,
        campaign_id: campaign_id,
        # List of template IDs assigned to this phone
        template_ids: template_ids,
        # Cache: template_id => %{name, language} (loaded once, no DB queries during campaign)
        templates_cache: templates_cache
      }
    )
  end

  @doc """
  Required callback for Broadway when using non-atom names (like Registry via tuples).
  """
  @impl true
  def process_name({:via, Registry, {registry, phone_number_id}}, base_name) do
    {:via, Registry, {registry, {phone_number_id, base_name}}}
  end

  @doc """
  Stop a running pipeline for a phone number.
  """
  def stop(phone_number_id) do
    case Registry.lookup(TitanFlow.Campaigns.PipelineRegistry, phone_number_id) do
      [{pid, _}] -> Broadway.stop(pid)
      [] -> {:error, :not_found}
    end
  end

  # Broadway Callbacks

  @impl true
  def handle_message(_processor, %Message{data: data} = message, context) do
    %{
      phone_number_id: phone_number_id,
      campaign_id: campaign_id,
      template_ids: template_ids,
      templates_cache: templates_cache
    } = context

    # Removed verbose logging for performance

    # Check if campaign is paused - if so, re-queue safely
    if Orchestrator.is_paused?(campaign_id) do
      # Campaign paused - requeue silently
      # Re-queue the message back to Redis (at the tail)
      requeue_message(campaign_id, phone_number_id, data)
      # Sleep to prevent hot loop
      Process.sleep(5000)
      # Acknowledge to Broadway (don't fail - that causes data loss)
      message
    else
      # Check if THIS phone is exhausted (no cross-phone routing to prevent contamination)
      if phone_exhausted?(campaign_id, phone_number_id) do
        # Phone exhausted - mark as FAILED (NOT requeued)
        # These failed messages can be retried via "Retry Failed" button after campaign completes
        case Jason.decode(data) do
          {:ok, payload} ->
            contact_id = payload["contact_id"]
            phone = payload["phone"]

            MessageTracking.record_failed(
              campaign_id,
              contact_id,
              phone,
              # template_name
              "N/A",
              "PHONE_EXHAUSTED",
              "Phone #{phone_number_id} has all templates exhausted",
              phone_number_id
            )

          _ ->
            :ok
        end

        Message.failed(message, "Phone exhausted - all templates failed")
      else
        # Phone is active - process normally with THIS phone's templates only
        case Jason.decode(data) do
          {:ok, payload} ->
            # Get healthy templates for THIS phone only
            healthy_templates = get_healthy_templates(campaign_id, phone_number_id, template_ids)

            if Enum.empty?(healthy_templates) do
              # All templates exhausted for this phone - mark phone as exhausted
              require Logger

              Logger.error(
                "All templates exhausted for phone #{phone_number_id} in campaign #{campaign_id}"
              )

              mark_phone_exhausted(campaign_id, phone_number_id)
              Message.failed(message, "All templates exhausted for this phone")
            else
              # Try sending with fallback logic (pass cache for fast lookups)
              try_send_with_template_fallback(
                message,
                payload,
                phone_number_id,
                campaign_id,
                healthy_templates,
                0,
                templates_cache
              )
            end

          {:error, _reason} ->
            Message.failed(message, "Invalid JSON payload")
        end
      end
    end
  end

  # Simple check if THIS phone is exhausted (no fallback to other phones)
  defp phone_exhausted?(campaign_id, phone_number_id) do
    case Redix.command(:redix, [
           "SISMEMBER",
           "campaign:#{campaign_id}:exhausted_phones",
           phone_number_id
         ]) do
      {:ok, 1} -> true
      _ -> false
    end
  end

  # Load templates into memory cache at startup (eliminates DB queries during campaign)
  # This is CRITICAL for DB performance - must succeed to avoid 100s of queries/sec
  defp load_templates_into_cache(template_ids)
       when is_list(template_ids) and length(template_ids) > 0 do
    require Logger

    try do
      # Use batch query instead of individual gets for better reliability
      import Ecto.Query

      templates =
        TitanFlow.Repo.all(
          from t in TitanFlow.Templates.Template,
            where: t.id in ^template_ids,
            select: %{id: t.id, name: t.name, language: t.language}
        )

      # Build cache map
      cache =
        templates
        |> Enum.map(fn t ->
          {t.id, %{name: t.name, language: t.language || "en"}}
        end)
        |> Map.new()

      # Verify all templates were loaded
      missing = template_ids -- Map.keys(cache)

      if length(missing) > 0 do
        Logger.error("Template cache INCOMPLETE: Missing template IDs #{inspect(missing)}")
        Logger.error("Requested: #{inspect(template_ids)}, Loaded: #{inspect(Map.keys(cache))}")
      else
        Logger.info("Template cache loaded successfully: #{map_size(cache)} templates cached")
      end

      cache
    rescue
      e ->
        Logger.error("CRITICAL: Failed to load templates into cache!")
        Logger.error("Error: #{inspect(e)}")
        Logger.error("Template IDs: #{inspect(template_ids)}")
        Logger.error("This will cause DB overload - Pipeline will query DB for each message")

        # Return empty map - Pipeline will fall back to DB queries (slow but works)
        %{}
    end
  end

  defp load_templates_into_cache([]) do
    require Logger
    Logger.warning("No template IDs provided for cache - this campaign has no templates!")
    %{}
  end

  defp requeue_message(campaign_id, phone_number_id, data) do
    queue_name = "queue:sending:#{campaign_id}:#{phone_number_id}"
    Redix.command(:redix, ["RPUSH", queue_name, data])
  end

  # Private Functions

  # Get templates that haven't failed for this phone in this campaign
  defp get_healthy_templates(campaign_id, phone_number_id, template_ids) do
    key = "campaign:#{campaign_id}:phone:#{phone_number_id}:failed_templates"

    case Redix.command(:redix, ["SMEMBERS", key]) do
      {:ok, failed_template_ids} ->
        # Convert failed IDs from strings to integers
        failed_ids =
          Enum.map(failed_template_ids, fn id_str ->
            case Integer.parse(id_str) do
              {id, _} -> id
              :error -> nil
            end
          end)
          |> Enum.reject(&is_nil/1)

        # Filter out failed templates
        Enum.reject(template_ids, fn tid -> tid in failed_ids end)

      _ ->
        # Redis error - return all templates (fail-safe)
        template_ids
    end
  end

  # Mark a template as failed/exhausted for a specific phone in a campaign
  defp mark_template_exhausted(campaign_id, phone_number_id, template_id, error_code) do
    key = "campaign:#{campaign_id}:phone:#{phone_number_id}:failed_templates"
    Redix.command(:redix, ["SADD", key, to_string(template_id)])

    require Logger

    Logger.warning(
      "Template #{template_id} marked as exhausted for phone #{phone_number_id} in campaign #{campaign_id} (error: #{error_code})"
    )
  end

  # Mark entire phone as exhausted (all templates failed)
  defp mark_phone_exhausted(campaign_id, phone_number_id) do
    # Mark phone as exhausted in Redis
    Redix.command(:redix, ["SADD", "campaign:#{campaign_id}:exhausted_phones", phone_number_id])

    # Check if ALL phones are now exhausted
    {:ok, exhausted_phones} =
      Redix.command(:redix, ["SMEMBERS", "campaign:#{campaign_id}:exhausted_phones"])

    # Get campaign to check total phone count
    campaign = TitanFlow.Campaigns.get_campaign!(campaign_id)
    total_phones = length(campaign.phone_ids || [])

    if length(exhausted_phones) >= total_phones do
      # All phones exhausted - pause campaign with message
      require Logger
      Logger.error("All #{total_phones} phones exhausted for campaign #{campaign_id} - pausing")

      Orchestrator.pause_campaign(campaign_id)

      TitanFlow.Campaigns.update_campaign(campaign, %{
        error_message: "All numbers exhausted"
      })
    end
  end

  # Try sending with template fallback - sequentially tries each healthy template
  defp try_send_with_template_fallback(
         message,
         _payload,
         _phone_number_id,
         _campaign_id,
         [],
         _attempt,
         _templates_cache
       ) do
    # No more templates to try
    Message.failed(message, "All templates failed")
  end

  defp try_send_with_template_fallback(
         message,
         payload,
         phone_number_id,
         campaign_id,
         [template_id | remaining_templates],
         attempt,
         templates_cache
       ) do
    # Get template from local cache (0ms lookup vs ~5-10ms DB query)
    {template_name, language} =
      case Map.get(templates_cache, template_id) do
        nil ->
          # Local cache miss - try global ETS cache first (Phase 2: 4A)
          require Logger

          case TitanFlow.Templates.TemplateCache.get(template_id) do
            {:ok, template} ->
              Logger.debug("Template #{template_id} found in ETS cache")
              {template.name, template.language || "en"}

            _ ->
              # ETS cache miss too - fall back to DB (last resort)
              Logger.warning("Template #{template_id} not in any cache, fetching from DB")
              template = TitanFlow.Templates.get_template!(template_id)
              {template.name, template.language || "en"}
          end

        cached_template ->
          # Use local cached template data (fastest!)
          {cached_template.name, cached_template.language}
      end

    # CRITICAL: Check if template is paused (e.g., UTILITY → MARKETING via webhook)
    if TitanFlow.Campaigns.Cache.is_template_paused?(template_name) do
      require Logger

      Logger.warning(
        "Template #{template_name} (ID: #{template_id}) is PAUSED (likely category changed), skipping to next template"
      )

      mark_template_exhausted(campaign_id, phone_number_id, template_id, "template_paused")
      # Try next template immediately
      try_send_with_template_fallback(
        message,
        payload,
        phone_number_id,
        campaign_id,
        remaining_templates,
        attempt + 1,
        templates_cache
      )
    else
      # Template is active, proceed with sending
      # Try sending with this template
      result =
        dispatch_with_retry(
          message,
          payload,
          phone_number_id,
          campaign_id,
          template_name,
          language,
          0
        )

      # Check if we should try the next template
      case result do
        %Broadway.Message{status: {:failed, reason}} ->
          # Check if this was a template-specific error that warrants fallback
          error_code =
            case reason do
              {:api_error, code, _msg} -> code
              _ -> nil
            end

          if error_code &&
               should_try_next_template?(error_code, template_id, campaign_id, phone_number_id) do
            # Try next template (pass cache through)
            try_send_with_template_fallback(
              message,
              payload,
              phone_number_id,
              campaign_id,
              remaining_templates,
              attempt + 1,
              templates_cache
            )
          else
            # Non-retriable error, return failure
            result
          end

        _ ->
          # Success or other status
          result
      end
    end
  end

  # Determine if we should try the next template based on the error code
  # Now accepts the actual Meta error code directly, not a string to parse
  defp should_try_next_template?(error_code, template_id, campaign_id, phone_number_id) do
    # Normalize to integer if it's a string
    code =
      case error_code do
        c when is_integer(c) ->
          c

        c when is_binary(c) ->
          case Integer.parse(c) do
            {n, _} -> n
            :error -> 0
          end

        _ ->
          0
      end

    cond do
      # CRITICAL: Payment/Account errors - mark PHONE as exhausted, not just template
      code in [131_042, 131_053] ->
        require Logger

        Logger.error(
          "PAYMENT ERROR #{code} detected for phone #{phone_number_id} - marking phone as EXHAUSTED"
        )

        mark_phone_exhausted(campaign_id, phone_number_id)
        # Don't try next template, phone is dead
        false

      # Template-specific errors - try next template
      code in [132_000, 132_001, 132_015, 132_016, 132_068, 133_004] ->
        require Logger

        Logger.warning(
          "Template error #{code} for template #{template_id} - trying next template"
        )

        mark_template_exhausted(campaign_id, phone_number_id, template_id, "#{code}")
        true

      # Rate limit and temporary errors - don't try next template, let retry handle it
      code in [429, 131_047, 130_429] ->
        false

      # Unknown error - don't try next template
      true ->
        false
    end
  end

  defp dispatch_with_retry(
         message,
         payload,
         phone_number_id,
         campaign_id,
         template_name,
         language_code,
         retry_count
       ) do
    alias TitanFlow.WhatsApp.Client

    # Step 1: Check rate limit (fast, non-blocking)
    case RateLimiter.dispatch(phone_number_id, nil) do
      {:ok, :allowed, access_token} ->
        # Step 2: Make HTTP call directly (parallel with processors)
        components = build_components(payload)
        credentials = %{access_token: access_token, phone_number_id: phone_number_id}

        result =
          Client.send_template(
            payload["phone"],
            template_name,
            language_code,
            components,
            credentials
          )

        case result do
          {:ok, body, _headers} ->
            # Extract message ID from response and record it for tracking
            meta_message_id = get_in(body, ["messages", Access.at(0), "id"])
            contact_id = payload["contact_id"]
            recipient_phone = payload["phone"]

            if meta_message_id do
              # IMPORTANT: Increment counter synchronously BEFORE async task
              # This prevents counter loss if the task crashes
              Redix.command(:redix, ["INCR", "campaign:#{campaign_id}:sent_count"])

              # Fire-and-forget: buffer log entry (counter already incremented above)
              Task.start(fn ->
                MessageTracking.record_sent_no_counter(
                  meta_message_id,
                  campaign_id,
                  contact_id,
                  recipient_phone,
                  template_name,
                  phone_number_id
                )
              end)
            end

            message

          {:error, {:api_error, 429, _body, _headers}} ->
            # 429 - notify RateLimiter (pauses for 10s) and record failure
            # Increment failed counter synchronously
            RateLimiter.notify_rate_limited(phone_number_id)
            Redix.command(:redix, ["INCR", "campaign:#{campaign_id}:failed_count"])

            Task.start(fn ->
              MessageTracking.record_failed_no_counter(
                campaign_id,
                payload["contact_id"],
                payload["phone"],
                template_name,
                "130429",
                "Rate limited (429)",
                phone_number_id
              )
            end)

            Message.failed(message, "Rate limited (429)")

          {:error, {:api_error, status_code, body, _headers}} ->
            # API error with status code - record the failure with error details
            error_message = extract_api_error_message(body)
            error_code = extract_api_error_code(body) || status_code

            if to_string(error_code) == "131048" do
              # Spam rate limit - pause this phone for 60s, then resume
              RateLimiter.notify_spam_rate_limited(phone_number_id)

              Task.start(fn ->
                MessageTracking.record_failed(
                  campaign_id,
                  payload["contact_id"],
                  payload["phone"],
                  template_name,
                  error_code,
                  error_message,
                  phone_number_id
                )
              end)
            else
              # CRITICAL ERROR HANDLING: Payment errors must be synchronous
              # to immediately mark phone as exhausted and prevent wasted sends
              if is_critical_error?(error_code) do
                # Synchronous for payment/account errors - phone exhaustion MUST happen NOW
                MessageTracking.record_failed(
                  campaign_id,
                  payload["contact_id"],
                  payload["phone"],
                  template_name,
                  error_code,
                  error_message,
                  phone_number_id
                )

                require Logger

                Logger.error(
                  "Critical error #{error_code} for phone #{phone_number_id}: #{error_message}"
                )
              else
                # Async for non-critical errors - maintain speed
                Task.start(fn ->
                  MessageTracking.record_failed(
                    campaign_id,
                    payload["contact_id"],
                    payload["phone"],
                    template_name,
                    error_code,
                    error_message,
                    phone_number_id
                  )
                end)
              end
            end

            # Return failure with error code embedded for fallback decision
            Message.failed(message, {:api_error, error_code, error_message})

          {:error, reason} ->
            # Generic error - record failure
            Task.start(fn ->
              MessageTracking.record_failed(
                campaign_id,
                payload["contact_id"],
                payload["phone"],
                template_name,
                0,
                "API error: #{inspect(reason)}",
                phone_number_id
              )
            end)

            Message.failed(message, "API error: #{inspect(reason)}")
        end

      {:error, :rate_limited} when retry_count < @max_retries ->
        # Local rate limit hit - backoff and retry without marking failed
        Process.sleep(@retry_delay_ms * (retry_count + 1))

        dispatch_with_retry(
          message,
          payload,
          phone_number_id,
          campaign_id,
          template_name,
          language_code,
          retry_count + 1
        )

      {:error, :rate_limited} ->
        # Still rate limited - requeue and ack without failure
        Process.sleep(@retry_delay_ms * (retry_count + 1))
        requeue_message(campaign_id, phone_number_id, Jason.encode!(payload))
        message

      {:error, reason} ->
        # Dispatch error - record failure
        Task.start(fn ->
          MessageTracking.record_failed(
            campaign_id,
            payload["contact_id"],
            payload["phone"],
            template_name,
            0,
            "Dispatch failed: #{inspect(reason)}",
            phone_number_id
          )
        end)

        Message.failed(message, "Dispatch failed: #{inspect(reason)}")
    end
  end

  defp build_components(payload) do
    # Build template components from contact variables
    # variables contains: %{"var1" => "...", "var2" => "...", "media_url" => "..."}
    variables = payload["variables"] || %{}

    components = []

    # Build HEADER component if media_url exists
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

    # Build BODY parameters from var1, var2, etc. (sorted by key)
    body_params =
      variables
      |> Enum.filter(fn {key, _} -> String.starts_with?(key, "var") end)
      |> Enum.sort_by(fn {key, _} -> key end)
      |> Enum.map(fn {_key, value} ->
        %{"type" => "text", "text" => to_string(value)}
      end)

    # Add body component if there are parameters
    components =
      if Enum.empty?(body_params) do
        components
      else
        [%{"type" => "body", "parameters" => body_params} | components]
      end

    # Reverse to get header first, then body
    Enum.reverse(components)
  end

  defp via_tuple(phone_number_id) do
    {:via, Registry, {TitanFlow.Campaigns.PipelineRegistry, phone_number_id}}
  end

  # Extract error message from Meta API response body
  defp extract_api_error_message(body) when is_map(body) do
    # Meta error format: {"error": {"message": "...", "code": 123, ...}}
    get_in(body, ["error", "message"]) ||
      get_in(body, ["error", "error_data", "details"]) ||
      inspect(body)
  end

  defp extract_api_error_message(body), do: inspect(body)

  # Extract error code from Meta API response body
  defp extract_api_error_code(body) when is_map(body) do
    # Meta error codes: 132001 = template paused, 131047 = rate limit, etc.
    get_in(body, ["error", "code"]) ||
      get_in(body, ["error", "error_subcode"])
  end

  defp extract_api_error_code(_body), do: nil

  # Check if error code is critical (payment/account issues)
  # Critical errors require SYNCHRONOUS handling to immediately mark phone as exhausted
  defp is_critical_error?(error_code) when is_integer(error_code) do
    error_code in [
      # Payment issue (most common)
      131_042,
      # Account flagged 
      # Account locked
      131_053
    ]
  end

  defp is_critical_error?(error_code) when is_binary(error_code) do
    error_code in ["131042", "131053"]
  end

  defp is_critical_error?(_), do: false
end
