defmodule TitanFlowWeb.WebhookController do
  @moduledoc """
  Controller for WhatsApp webhook verification and ingestion.
  """
  use TitanFlowWeb, :controller

  alias TitanFlow.Inbox
  alias TitanFlow.AI.Handler, as: AIHandler
  alias TitanFlow.Campaigns.QualityMonitor

  require Logger



  @doc """
  GET /api/webhooks/whatsapp - Webhook verification for Meta
  """
  def verify(conn, params) do
    mode = params["hub.mode"]
    token = params["hub.verify_token"]
    challenge = params["hub.challenge"]

    if mode == "subscribe" && token == get_verify_token() do
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(200, challenge)
    else
      send_resp(conn, 403, "Forbidden")
    end
  end

  @doc """
  POST /api/webhooks/whatsapp - Webhook ingestion for Meta
  """
  def handle(conn, params) do
    # Always return 200 OK immediately to keep Meta happy
    # Process in background
    Task.start(fn -> process_webhook(params) end)

    conn
    |> put_status(200)
    |> json(%{status: "ok"})
  end

  defp get_verify_token do
    Application.get_env(:titan_flow, :webhook_verify_token, "titanflow_webhook_secret")
  end

  defp process_webhook(%{"entry" => entries}) do
    Enum.each(entries, fn entry ->
      changes = entry["changes"] || []
      Enum.each(changes, &process_change/1)
    end)
  end
  defp process_webhook(_), do: :ok

  defp process_change(%{"value" => value, "field" => "message_template_status_update"}) do
    # Handle template quality/status webhooks
    # Meta sends these when a template is PAUSED, FLAGGED, DISABLED, or REJECTED
    handle_template_status_update(value)
  end

  defp process_change(%{"value" => value}) do
    # Handle status updates
    if statuses = value["statuses"] do
      handle_statuses(statuses, value)
    end

    # Handle incoming messages
    if messages = value["messages"] do
      handle_messages(messages, value)
    end
  end
  defp process_change(_), do: :ok

  # Handle template quality/status webhooks for late-binding template switching
  defp handle_template_status_update(value) do
    event = value["event"]
    template_name = value["message_template_name"]
    new_status = value["message_template_status"]
    new_category = value["message_template_category"]
    
    Logger.info("Template update: #{template_name} -> Status: #{new_status}, Category: #{new_category} (event: #{event})")
    
    # Fetch template from DB to compare
    case TitanFlow.Templates.get_template_by_name(template_name) do
      nil ->
        Logger.warning("Template update received for unknown template: #{template_name}")
        :ok
        
      db_template ->
        # Check for status degradation or category change
        should_switch = cond do
          should_trigger_fallback?(new_status) ->
            Logger.warning("Template #{template_name}: Status degraded to #{new_status}")
            true
            
          new_category != nil and new_category != db_template.category ->
            Logger.warning("Template #{template_name}: Category changed from #{db_template.category} to #{new_category}")
            true
            
          new_status != "APPROVED" and db_template.status == "APPROVED" ->
            Logger.warning("Template #{template_name}: Status no longer APPROVED (was: #{db_template.status}, now: #{new_status})")
            true
            
          true ->
            false
        end
        
        if should_switch do
          # Update template in DB
          TitanFlow.Templates.update_template(db_template, %{
            status: new_status,
            category: new_category || db_template.category
          })
          
          # Cache the paused status in Redis for fast Pipeline pre-flight check
          alias TitanFlow.Campaigns.Cache
          Cache.mark_template_paused(template_name)
          Logger.warning("Template #{template_name} marked as PAUSED in Redis cache")
          
          # Trigger switch for all affected campaigns
          QualityMonitor.switch_template(db_template.id)
        else
          # Just update status in DB and clear paused status if approved
          TitanFlow.Templates.update_template(db_template, %{
            status: new_status,
            category: new_category || db_template.category
          })
          
          # Clear paused cache if template is now approved
          if new_status == "APPROVED" do
            alias TitanFlow.Campaigns.Cache
            Cache.clear_template_paused(template_name)
          end
        end
    end
  end

  defp should_trigger_fallback?(status) do
    status in ["PAUSED", "FLAGGED", "DISABLED", "REJECTED"]
  end

  defp trigger_fallback_for_template(template_name, webhook_status) do
    # Get all active campaigns - for each one using this template, trigger fallback switch
    # Note: In production, you'd want to query campaigns by template_name more efficiently
    campaigns = TitanFlow.Campaigns.list_campaigns()
    
    Enum.each(campaigns, fn campaign ->
      case campaign.status do
        campaign_status when campaign_status in ["running", "importing", "ready"] ->
          # Check if this campaign is affected by querying the cache
          case TitanFlow.Campaigns.Cache.get_active_template(campaign.id) do
            {:ok, %{template_name: ^template_name}} ->
              Logger.warning("Campaign #{campaign.id}: Template #{template_name} status changed to #{webhook_status}, switching to fallback")
              QualityMonitor.switch_template_if_needed(campaign.id, webhook_status, template_name)
            _ ->
              :ok  # This campaign uses a different template
          end
        _ ->
          :ok  # Campaign not active
      end
    end)
  end

  # Handle status updates (sent/delivered/read/failed)
  defp handle_statuses(statuses, value) do
    phone_number_id = get_in(value, ["metadata", "phone_number_id"])
    
    alias TitanFlow.Campaigns.MessageTracking
    
    Enum.each(statuses, fn status ->
      message_id = status["id"]
      message_status = status["status"]
      timestamp = parse_timestamp(status["timestamp"])
      error_code = get_in(status, ["errors", Access.at(0), "code"])
      error_message = get_in(status, ["errors", Access.at(0), "message"])
      
      # Update message tracking (connects to campaign statistics)
      MessageTracking.update_status(message_id, message_status,
        timestamp: timestamp,
        error_code: error_code,
        error_message: error_message
      )
    end)
  end

  # Handle incoming messages (OPTIMIZED: reduced from 6 queries to 3-4)
  defp handle_messages(messages, value) do
    phone_number_id = get_in(value, ["metadata", "phone_number_id"])
    contacts = value["contacts"] || []

    # CACHED lookup - eliminates DB query after first hit
    alias TitanFlow.WhatsApp.PhoneCache
    phone_db_id = PhoneCache.get_db_id(phone_number_id)
    
    if is_nil(phone_db_id) do
      Logger.warning("Webhook: Unknown phone_number_id: #{phone_number_id}")
    else
      Enum.each(messages, fn msg ->
        process_single_message(msg, phone_db_id, phone_number_id, contacts)
      end)
    end
  end

  # Process a single incoming message with optimized DB operations
  defp process_single_message(msg, phone_db_id, phone_number_id, contacts) do
    meta_message_id = msg["id"]
    contact = Enum.find(contacts, fn c -> c["wa_id"] == msg["from"] end)
    contact_name = get_in(contact, ["profile", "name"])
    contact_phone = msg["from"]
    content = extract_message_content(msg)

    # ATOMIC: Upsert conversation - single query for insert OR update + increment unread
    case Inbox.upsert_conversation(contact_phone, phone_db_id, contact_name) do
      {:ok, conversation} ->
        # DEDUP: Create message with conflict handling - single query with on_conflict
        case Inbox.create_message_dedup(%{
          conversation_id: conversation.id,
          direction: "inbound",
          content: content,
          message_type: msg["type"] || "text",
          meta_message_id: meta_message_id
        }) do
          {:ok, message} ->
            # Update conversation preview (single UPDATE query)
            Inbox.update_conversation_preview(conversation.id, content)
            
            # Broadcast to PubSub for real-time UI updates
            Inbox.broadcast_new_message(message, conversation)

            # Trigger AI processing asynchronously
            AIHandler.process_message(%{
              message: message,
              conversation: conversation,
              phone_number_id: phone_number_id,
              raw_msg: msg
            })

            # Record reply for campaign tracking (single UPDATE query)
            TitanFlow.Campaigns.MessageTracking.record_reply(phone_number_id, contact_phone)
            
          {:duplicate, _} ->
            Logger.debug("Skipping duplicate message: #{meta_message_id}")
            
          {:error, changeset} ->
            Logger.error("Failed to create message: #{inspect(changeset.errors)}")
        end
        
      {:error, reason} ->
        Logger.error("Failed to upsert conversation: #{inspect(reason)}")
    end
  end

  defp extract_message_content(%{"type" => "text", "text" => %{"body" => body}}), do: body
  defp extract_message_content(%{"type" => "button", "button" => %{"text" => text}}), do: text
  defp extract_message_content(%{"type" => "interactive", "interactive" => interactive}) do
    get_in(interactive, ["button_reply", "title"]) || 
    get_in(interactive, ["list_reply", "title"]) ||
    "[Interactive reply]"
  end
  defp extract_message_content(%{"type" => type}), do: "[#{type} message]"
  defp extract_message_content(_), do: "[Unknown message]"

  defp get_phone_number_db_id(phone_number_id) do
    case TitanFlow.WhatsApp.get_by_phone_number_id(phone_number_id) do
      nil -> nil
      phone -> phone.id
    end
  end

  defp parse_timestamp(nil), do: DateTime.utc_now()
  defp parse_timestamp(ts) when is_binary(ts) do
    case Integer.parse(ts) do
      {unix, _} -> DateTime.from_unix!(unix)
      :error -> DateTime.utc_now()
    end
  end
  defp parse_timestamp(ts) when is_integer(ts), do: DateTime.from_unix!(ts)

  # ClickHouse logging removed - all logging now done via MessageTracking to Postgres
end

