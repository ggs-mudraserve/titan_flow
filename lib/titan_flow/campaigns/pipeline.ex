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
  alias TitanFlow.Campaigns.{Cache, Orchestrator}

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
    
    redix_config = Keyword.get_lazy(opts, :redis_config, fn ->
      Application.get_env(:titan_flow, :redix)
    end)

    queue_name = "queue:sending:#{phone_number_id}"

    Broadway.start_link(__MODULE__,
      name: via_tuple(phone_number_id),
      producer: [
        module: {
          TitanFlow.Campaigns.RedisProducer,
          redis_config: redix_config,
          list_name: queue_name,
          batch_size: 200
        },
        concurrency: 1
      ],
      processors: [
        default: [
          concurrency: 200
        ]
      ],
      context: %{
        phone_number_id: phone_number_id,
        campaign_id: campaign_id,
        # List of template IDs assigned to this phone
        template_ids: template_ids
      }
    )
  end

  @doc """
  Required callback for Broadway when using non-atom names (like Registry via tuples).
  """
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
      template_ids: template_ids
    } = context

    # Check if campaign is paused - if so, re-queue safely
    if Orchestrator.is_paused?(campaign_id) do
      # Re-queue the message back to Redis (at the tail)
      requeue_message(phone_number_id, data)
      # Sleep to prevent hot loop
      Process.sleep(5000)
      # Acknowledge to Broadway (don't fail - that causes data loss)
      message
    else
      # Check if this phone is exhausted (payment errors)
      try do
        case get_valid_phone(campaign_id, phone_number_id) do
          {:ok, active_phone_id} ->
            # Get contact_id from message data for template rotation
            contact_id = case Jason.decode(data) do
              {:ok, payload} -> payload["contact_id"] || 0
              _ -> 0
            end
            
            # Use contact_id for deterministic template selection (round-robin per contact)
            # This ensures consistent template selection even after pipeline restarts
            {template_name, language_code} = get_template_for_phone(template_ids, contact_id)

            case Jason.decode(data) do
              {:ok, payload} ->
                # Wrap in try/rescue to handle unexpected errors gracefully
                try do
                  dispatch_with_retry(message, payload, active_phone_id, campaign_id, template_name, language_code, 0)
                rescue
                  e ->
                    require Logger
                    Logger.error("Dispatch error for #{payload["phone"]}: #{inspect(e)}")
                    # Skip this message but don't crash the pipeline
                    message
                end

              {:error, _reason} ->
                Message.failed(message, "Invalid JSON payload")
            end

          {:error, :all_phones_exhausted} ->
            # All phones exhausted - pause and re-queue
            Orchestrator.pause_campaign(campaign_id)
            requeue_message(phone_number_id, data)
            message
        end
      catch
        :all_templates_exhausted ->
          # Campaign paused due to template exhaustion - message was re-queued
          message
      end
    end
  end

  # Check if phone is exhausted, return valid phone or error
  defp get_valid_phone(campaign_id, current_phone_id) do
    case Redix.command(:redix, ["SISMEMBER", "campaign:#{campaign_id}:exhausted_phones", current_phone_id]) do
      {:ok, 0} ->
        # Not exhausted, use current phone
        {:ok, current_phone_id}
      
      {:ok, 1} ->
        # Current phone is exhausted, try to find an alternative
        find_alternative_phone(campaign_id)
      
      _ ->
        # Redis error, assume current phone is ok
        {:ok, current_phone_id}
    end
  end

  defp find_alternative_phone(campaign_id) do
    # Get campaign to find all phone_ids
    campaign = TitanFlow.Campaigns.get_campaign!(campaign_id)
    phone_ids = campaign.phone_ids || []
    
    # Get phones that are linked (have phone_number_id)
    phones = Enum.map(phone_ids, fn id ->
      TitanFlow.WhatsApp.get_phone_number!(id)
    end)
    phone_number_ids = Enum.map(phones, & &1.phone_number_id)
    
    # Get exhausted phones
    {:ok, exhausted} = Redix.command(:redix, ["SMEMBERS", "campaign:#{campaign_id}:exhausted_phones"])
    exhausted = exhausted || []
    
    # Find first non-exhausted phone
    valid_phones = Enum.filter(phone_number_ids, fn pid -> pid not in exhausted end)
    
    case valid_phones do
      [first | _] -> {:ok, first}
      [] -> {:error, :all_phones_exhausted}
    end
  end

  defp requeue_message(phone_number_id, data) do
    queue_name = "queue:sending:#{phone_number_id}"
    Redix.command(:redix, ["RPUSH", queue_name, data])
  end

  # Private Functions

  defp get_template_for_phone(template_ids, contact_id) when length(template_ids) > 0 do
    # Use contact_id modulo template count for deterministic round-robin
    # This ensures: contact 1 -> template #0, contact 2 -> template #1, etc.
    # Benefits: Stateless, survives pipeline restarts, distributes templates evenly
    template_index = rem(contact_id, length(template_ids))
    template_id = Enum.at(template_ids, template_index)
    
    # Fetch template from database
    template = TitanFlow.Templates.get_template!(template_id)
    
    {template.name, template.language || "en"}
  end
  defp get_template_for_phone([], _contact_id) do
    # No templates configured - this shouldn't happen but provide fallback
    require Logger
    Logger.error("No templates configured for this phone")
    {"default", "en"}
  end

  defp dispatch_with_retry(message, payload, phone_number_id, campaign_id, template_name, language_code, retry_count) do
    alias TitanFlow.Campaigns.MessageTracking
    alias TitanFlow.WhatsApp.Client
    
    # Step 1: Check rate limit (fast, non-blocking)
    case RateLimiter.dispatch(phone_number_id, nil) do
      {:ok, :allowed, access_token} ->
        # Step 2: Make HTTP call directly (parallel with 50 processors)
        components = build_components(payload)
        credentials = %{access_token: access_token, phone_number_id: phone_number_id}
        
        result = Client.send_template(
          payload["phone"],
          template_name,
          language_code,
          components,
          credentials
        )
        
        case result do
          {:ok, body, headers} ->
            # Send headers back to RateLimiter for throttle adjustment
            RateLimiter.update_stats(phone_number_id, headers)
            
            # Extract message ID from response and record it for tracking
            meta_message_id = get_in(body, ["messages", Access.at(0), "id"])
            contact_id = payload["contact_id"]
            recipient_phone = payload["phone"]
            
            if meta_message_id do
              # Fire-and-forget: don't block on database insert
              Task.start(fn ->
                MessageTracking.record_sent(meta_message_id, campaign_id, contact_id, recipient_phone, template_name, phone_number_id)
              end)
            end
            
            message

          {:error, {:api_error, 429, _body, _headers}} ->
            # 429 - notify RateLimiter and retry
            RateLimiter.notify_rate_limited(phone_number_id)
            if retry_count < @max_retries do
              Process.sleep(1000)
              dispatch_with_retry(message, payload, phone_number_id, campaign_id, template_name, language_code, retry_count + 1)
            else
              # Max retries exceeded - record failure
              Task.start(fn ->
                MessageTracking.record_failed(
                  campaign_id, payload["contact_id"], payload["phone"], 
                  template_name, 429, "Rate limited after #{@max_retries} retries", phone_number_id
                )
              end)
              Message.failed(message, "Rate limited after #{@max_retries} retries")
            end

          {:error, {:api_error, status_code, body, _headers}} ->
            # API error with status code - record the failure with error details
            error_message = extract_api_error_message(body)
            error_code = extract_api_error_code(body) || status_code
            
            # CRITICAL ERROR HANDLING: Payment errors must be synchronous
            # to immediately mark phone as exhausted and prevent wasted sends
            if is_critical_error?(error_code) do
              # Synchronous for payment/account errors - phone exhaustion MUST happen NOW
              MessageTracking.record_failed(
                campaign_id, payload["contact_id"], payload["phone"],
                template_name, error_code, error_message, phone_number_id
              )
              require Logger
              Logger.error("Critical error #{error_code} for phone #{phone_number_id}: #{error_message}")
            else
              # Async for non-critical errors - maintain speed
              Task.start(fn ->
                MessageTracking.record_failed(
                  campaign_id, payload["contact_id"], payload["phone"],
                  template_name, error_code, error_message, phone_number_id
                )
              end)
            end
            Message.failed(message, "API error #{status_code}: #{error_message}")

          {:error, reason} ->
            # Generic error - record failure
            Task.start(fn ->
              MessageTracking.record_failed(
                campaign_id, payload["contact_id"], payload["phone"],
                template_name, 0, "API error: #{inspect(reason)}", phone_number_id
              )
            end)
            Message.failed(message, "API error: #{inspect(reason)}")
        end

      {:error, :rate_limited} when retry_count < @max_retries ->
        # Hammer rate limit hit - sleep and retry
        Process.sleep(@retry_delay_ms * (retry_count + 1))
        dispatch_with_retry(message, payload, phone_number_id, campaign_id, template_name, language_code, retry_count + 1)

      {:error, :rate_limited} ->
        # Max retries exceeded - record failure
        Task.start(fn ->
          MessageTracking.record_failed(
            campaign_id, payload["contact_id"], payload["phone"],
            template_name, 429, "Rate limited (Hammer) after #{@max_retries} retries", phone_number_id
          )
        end)
        Message.failed(message, "Rate limited after #{@max_retries} retries")

      {:error, reason} ->
        # Dispatch error - record failure
        Task.start(fn ->
          MessageTracking.record_failed(
            campaign_id, payload["contact_id"], payload["phone"],
            template_name, 0, "Dispatch failed: #{inspect(reason)}", phone_number_id
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
    components = if media_url && media_url != "" do
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
    components = if Enum.empty?(body_params) do
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
      131042,  # Payment issue (most common)
      131048,  # Account flagged 
      131053   # Account locked
    ]
  end
  defp is_critical_error?(error_code) when is_binary(error_code) do
    error_code in ["131042", "131048", "131053"]
  end
  defp is_critical_error?(_), do: false
end
