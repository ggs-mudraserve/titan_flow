defmodule TitanFlow.AI.Handler do
  @moduledoc """
  AI Handler for processing incoming WhatsApp messages using OpenAI GPT-4o-mini.
  """

  require Logger
  alias TitanFlow.WhatsApp
  alias TitanFlow.WhatsApp.Client
  alias TitanFlow.Inbox
  alias TitanFlow.Repo

  import Ecto.Query

  @openai_url "https://api.openai.com/v1/chat/completions"
  @model "gpt-4o-mini"

  @doc """
  Process an incoming message asynchronously.
  Checks AI pause, STOP keyword, then generates AI response.
  """
  def process_message(
        %{message: message, conversation: conversation, phone_number_id: phone_number_id} =
          _params
      ) do
    Task.start(fn ->
      do_process_message(message, conversation, phone_number_id)
    end)
  end

  defp do_process_message(message, conversation, phone_number_id) do
    # Get phone number record
    phone_number = WhatsApp.get_by_phone_number_id(phone_number_id)

    if is_nil(phone_number) do
      Logger.warning("Phone number not found for phone_number_id: #{phone_number_id}")
      :ok
    else
      # Step 1: Check if AI is paused for this conversation
      if conversation.is_ai_paused do
        Logger.info("AI paused for conversation #{conversation.id}")
        :ok
      else
        # Step 2: Check for STOP keyword
        content = String.downcase(message.content || "")

        if String.contains?(content, "stop") do
          handle_stop_command(conversation, phone_number)
        else
          # Step 3: Generate and send AI response
          generate_ai_response(message, conversation, phone_number)
        end
      end
    end
  end

  defp handle_stop_command(conversation, phone_number) do
    # Update contact as blacklisted (if contacts table has is_blacklisted field)
    # For now, pause AI for this conversation
    Inbox.toggle_ai_pause(conversation.id)

    # Send unsubscribe confirmation
    Client.send_text(
      phone_number.phone_number_id,
      conversation.contact_phone,
      "You have been unsubscribed. Reply START to re-subscribe.",
      phone_number.access_token
    )

    # Save outbound message
    Inbox.create_message(%{
      conversation_id: conversation.id,
      direction: "outbound",
      content: "You have been unsubscribed. Reply START to re-subscribe.",
      is_ai_generated: true
    })
  end

  defp generate_ai_response(_message, conversation, phone_number) do
    # Fetch last 5 messages for context
    recent_messages = get_recent_messages(conversation.id, 5)

    # Build conversation history for OpenAI
    messages = build_openai_messages(recent_messages, phone_number.system_prompt)

    # Resolve API Key from Global Settings, fallback to env
    api_key =
      TitanFlow.Settings.get_value("openai_api_key") ||
        Application.get_env(:titan_flow, :openai_api_key)

    # Call OpenAI API
    case call_openai(messages, api_key) do
      {:ok, response_text} ->
        # Send response via WhatsApp
        Client.send_text(
          phone_number.phone_number_id,
          conversation.contact_phone,
          response_text,
          phone_number.access_token
        )

        # Save AI response to database
        {:ok, ai_message} =
          Inbox.create_message(%{
            conversation_id: conversation.id,
            direction: "outbound",
            content: response_text,
            is_ai_generated: true
          })

        # Broadcast for real-time UI update
        updated_conversation = Inbox.get_conversation!(conversation.id)
        Inbox.broadcast_new_message(ai_message, updated_conversation)

      {:error, reason} ->
        Logger.error("OpenAI API error: #{inspect(reason)}")
    end
  end

  defp get_recent_messages(conversation_id, limit) do
    from(m in Inbox.Message,
      where: m.conversation_id == ^conversation_id,
      order_by: [desc: m.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
    |> Enum.reverse()
  end

  defp build_openai_messages(recent_messages, system_prompt) do
    system = %{
      "role" => "system",
      "content" =>
        system_prompt || "You are a helpful assistant. Keep answers short and friendly."
    }

    history =
      Enum.map(recent_messages, fn msg ->
        role = if msg.direction == "inbound", do: "user", else: "assistant"
        %{"role" => role, "content" => msg.content || ""}
      end)

    [system | history]
  end

  defp call_openai(messages, api_key) do
    if is_nil(api_key) or api_key == "" do
      {:error, :no_api_key}
    else
      body = %{
        model: @model,
        messages: messages,
        max_tokens: 300,
        temperature: 0.7
      }

      case Req.post(@openai_url,
             json: body,
             headers: [
               {"Authorization", "Bearer #{api_key}"},
               {"Content-Type", "application/json"}
             ],
             receive_timeout: 30_000
           ) do
        {:ok, %Req.Response{status: 200, body: response}} ->
          content = get_in(response, ["choices", Access.at(0), "message", "content"])
          {:ok, content}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          {:error, {:request_failed, reason}}
      end
    end
  end
end
