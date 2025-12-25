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

  Security: Verifies x-hub-signature-256 header using Meta app secret.
  """
  def handle(conn, params) do
    # SECURITY: Verify webhook signature before processing
    if verify_signature(conn) do
      # Always return 200 OK immediately to keep Meta happy
      # Process in background using supervised task (Phase 4: 5B)
      Task.Supervisor.start_child(TitanFlow.TaskSupervisor, fn -> process_webhook(params) end)

      conn
      |> put_status(200)
      |> json(%{status: "ok"})
    else
      Logger.warning("Webhook signature verification failed - rejecting request")

      conn
      |> put_status(401)
      |> json(%{error: "Invalid signature"})
    end
  end

  # Verify Meta webhook signature using HMAC-SHA256
  defp verify_signature(conn) do
    app_secret = Application.get_env(:titan_flow, :meta_app_secret)

    # If no app secret configured, skip verification (dev mode)
    if is_nil(app_secret) or app_secret == "" do
      Logger.warning("Webhook signature verification SKIPPED - meta_app_secret not configured")
      true
    else
      signature_header = get_req_header(conn, "x-hub-signature-256") |> List.first()

      if is_nil(signature_header) do
        Logger.warning("Missing x-hub-signature-256 header")
        false
      else
        # The raw body is stored by Plug.Parsers via body_reader
        raw_body = conn.assigns[:raw_body] || ""

        # Compute expected signature
        expected =
          "sha256=" <>
            (:crypto.mac(:hmac, :sha256, app_secret, raw_body)
             |> Base.encode16(case: :lower))

        # Constant-time comparison to prevent timing attacks
        Plug.Crypto.secure_compare(signature_header, expected)
      end
    end
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

  defp process_change(%{"value" => value, "field" => "template_category_update"}) do
    # Handle template category change webhooks (UTILITY -> MARKETING, etc.)
    # Meta sends these when a template's category is changed
    handle_template_category_update(value)
  end

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

  # Handle template category change webhooks (e.g., UTILITY -> MARKETING)
  defp handle_template_category_update(value) do
    template_name = value["message_template_name"] || value["templateName"]
    previous_category = value["previousCategory"] || value["previous_category"]
    new_category = value["newCategory"] || value["new_category"]

    Logger.warning(
      "Template category change: #{template_name} -> #{previous_category} to #{new_category}"
    )

    # Fetch template from DB
    case TitanFlow.Templates.get_template_by_name(template_name) do
      nil ->
        Logger.warning("Category update received for unknown template: #{template_name}")
        :ok

      db_template ->
        # Update category in DB
        TitanFlow.Templates.update_template(db_template, %{category: new_category})

        # Invalidate ETS cache
        TitanFlow.Templates.TemplateCache.invalidate(db_template.id)

        # If changed from UTILITY to MARKETING (or to any non-UTILITY), mark as paused
        if previous_category == "UTILITY" and new_category != "UTILITY" do
          alias TitanFlow.Campaigns.Cache
          Cache.mark_template_paused(template_name)

          Logger.warning(
            "Template #{template_name} changed from UTILITY to #{new_category} - marked as PAUSED"
          )

          # Trigger fallback for all affected campaigns
          QualityMonitor.switch_template(db_template.id)
        end
    end
  end

  # Handle template quality/status webhooks for late-binding template switching
  defp handle_template_status_update(value) do
    event = value["event"]
    template_name = value["message_template_name"]
    new_status = value["message_template_status"]
    new_category = value["message_template_category"]

    Logger.info(
      "Template update: #{template_name} -> Status: #{new_status}, Category: #{new_category} (event: #{event})"
    )

    # Fetch template from DB to compare
    case TitanFlow.Templates.get_template_by_name(template_name) do
      nil ->
        Logger.warning("Template update received for unknown template: #{template_name}")
        :ok

      db_template ->
        # Check for status degradation or category change
        should_switch =
          cond do
            should_trigger_fallback?(new_status) ->
              Logger.warning("Template #{template_name}: Status degraded to #{new_status}")
              true

            new_category != nil and new_category != db_template.category ->
              Logger.warning(
                "Template #{template_name}: Category changed from #{db_template.category} to #{new_category}"
              )

              true

            new_status != "APPROVED" and db_template.status == "APPROVED" ->
              Logger.warning(
                "Template #{template_name}: Status no longer APPROVED (was: #{db_template.status}, now: #{new_status})"
              )

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

          # Invalidate ETS cache so Pipeline picks up the change (Phase 4: 4C)
          TitanFlow.Templates.TemplateCache.invalidate(db_template.id)

          # Cache the paused status in Redis for fast Pipeline pre-flight check
          alias TitanFlow.Campaigns.Cache
          Cache.mark_template_paused(template_name)

          Logger.warning(
            "Template #{template_name} marked as PAUSED in Redis cache and ETS invalidated"
          )

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

  # DELETED: trigger_fallback_for_template/2 - was dead code referencing missing functions\n  # Legacy active-template switching removed; Pipeline now handles fallback per-message

  # Handle status updates (sent/delivered/read/failed)
  defp handle_statuses(statuses, _value) do
    # P2 FIX: Use WebhookBatcher for batched DB updates instead of direct writes
    alias TitanFlow.Campaigns.WebhookBatcher

    Enum.each(statuses, fn status ->
      message_id = status["id"]
      message_status = status["status"]
      # Keep as string, batcher will parse
      timestamp = status["timestamp"]
      error_code = get_in(status, ["errors", Access.at(0), "code"])
      error_message = get_in(status, ["errors", Access.at(0), "message"])

      # Queue for batch processing (returns immediately, no DB blocking)
      WebhookBatcher.queue_status_update(
        message_id,
        message_status,
        timestamp,
        error_code,
        error_message
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

  # ClickHouse logging removed - all logging now done via MessageTracking to Postgres
end
