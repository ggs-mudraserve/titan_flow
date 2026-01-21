defmodule TitanFlow.Campaigns.RetryManager do
  @moduledoc """
  Manages retry of failed messages after phone rotation.
  The "Heal" job - re-queues messages failed with 131042 to a working phone.
  """

  import Ecto.Query
  require Logger

  alias TitanFlow.Repo
  alias TitanFlow.Campaigns
  alias TitanFlow.Campaigns.MessageLog

  @max_retry_count 3

  @doc """
  Process failed messages from an exhausted phone and re-queue to active phone.
  Called automatically when a phone is marked as exhausted.

  - Queries message_logs for 131042 errors from this phone in the last hour
  - Re-queues them to the active phone's Redis queue
  - Tracks retry count to prevent infinite loops
  """
  def process_exhausted_phone(phone_number_id, campaign_id) do
    Logger.info(
      "RetryManager: Processing exhausted phone #{phone_number_id} for campaign #{campaign_id}"
    )

    # Find an active phone for this campaign
    case find_active_phone(campaign_id) do
      {:ok, active_phone_id} ->
        # Get failed messages from the last hour
        failed_messages = get_failed_messages_for_retry(phone_number_id, campaign_id)

        Logger.info("RetryManager: Found #{length(failed_messages)} failed messages to retry")

        # Re-queue each message to the active phone
        requeued_count =
          Enum.reduce(failed_messages, 0, fn msg, count ->
            case requeue_message(msg, active_phone_id, campaign_id) do
              :ok -> count + 1
              :skip -> count
            end
          end)

        Logger.info(
          "RetryManager: Re-queued #{requeued_count} messages to phone #{active_phone_id}"
        )

        {:ok, requeued_count}

      {:error, :no_active_phone} ->
        Logger.warning("RetryManager: No active phone available for campaign #{campaign_id}")
        {:error, :no_active_phone}
    end
  end

  defp find_active_phone(campaign_id) do
    campaign = Campaigns.get_campaign!(campaign_id)
    phone_ids = campaign.phone_ids || []

    # Get exhausted phones from Redis (stores phone_number_id strings)
    {:ok, exhausted} =
      Redix.command(:redix, ["SMEMBERS", "campaign:#{campaign_id}:exhausted_phones"])

    exhausted_set = MapSet.new(exhausted || [])

    # Find first non-exhausted phone by comparing phone_number_id (not DB id)
    active_phone =
      Enum.find(phone_ids, fn id ->
        phone = TitanFlow.WhatsApp.get_phone_number!(id)
        not MapSet.member?(exhausted_set, phone.phone_number_id)
      end)

    case active_phone do
      nil ->
        {:error, :no_active_phone}

      phone_id ->
        # Get the phone_number_id from DB
        phone = TitanFlow.WhatsApp.get_phone_number!(phone_id)
        {:ok, phone.phone_number_id}
    end
  end

  defp get_failed_messages_for_retry(phone_number_id, campaign_id) do
    one_hour_ago = DateTime.utc_now() |> DateTime.add(-3600, :second)

    query =
      from m in MessageLog,
        where: m.campaign_id == ^campaign_id,
        where: m.phone_number_id == ^phone_number_id,
        where: m.status == "failed",
        where: m.error_code in ["131042", "131048", "130429", "131005"],
        where: m.inserted_at >= ^one_hour_ago,
        select: m

    Repo.all(query)
  end

  @doc """
  Retry messages that failed due to a specific template error.
  Called when the campaign switches to a fallback template.
  """
  def retry_template_failure(template_name, campaign_id, _new_template_id) do
    Logger.info(
      "RetryManager: Retrying template failures for #{template_name} in campaign #{campaign_id}"
    )

    # 1. Find active phone (any non-exhausted phone)
    case find_active_phone(campaign_id) do
      {:ok, active_phone_id} ->
        # 2. Get messages failed due to this template in last hour
        failed_messages = get_failed_template_messages(template_name, campaign_id)

        # 3. Re-queue them
        count =
          Enum.reduce(failed_messages, 0, fn msg, acc ->
            # Reset error state so it doesn't look like a failure
            case requeue_message(msg, active_phone_id, campaign_id) do
              :ok -> acc + 1
              _ -> acc
            end
          end)

        Logger.info("RetryManager: Re-queued #{count} messages for template retry")
        {:ok, count}

      error ->
        Logger.error(
          "RetryManager: No active phone to retry template messages: #{inspect(error)}"
        )

        error
    end
  end

  @doc """
  Requeue a single failed message after a template webhook error so it can
  be retried with the next available template for the same phone.
  """
  def retry_template_message(message_log) do
    with {:ok, log} <- normalize_message_log(message_log),
         campaign_id when not is_nil(campaign_id) <- log.campaign_id,
         phone_number_id when not is_nil(phone_number_id) <- log.phone_number_id,
         recipient_phone when not is_nil(recipient_phone) <- log.recipient_phone,
         contact_id when not is_nil(contact_id) <- log.contact_id,
         false <- phone_exhausted?(campaign_id, to_string(phone_number_id)) do
      requeue_message(log, to_string(phone_number_id), campaign_id)
    else
      _ -> :skip
    end
  end

  defp get_failed_template_messages(template_name, campaign_id) do
    one_hour_ago = DateTime.utc_now() |> DateTime.add(-3600, :second)

    query =
      from m in MessageLog,
        where: m.campaign_id == ^campaign_id,
        where: m.template_name == ^template_name,
        where: m.status == "failed",
        where: m.inserted_at >= ^one_hour_ago,
        select: m

    Repo.all(query)
  end

  # Private functions (requeue_message, etc...)
  defp requeue_message(message_log, active_phone_id, campaign_id) do
    # Get or initialize retry count from Redis
    retry_key = "message:#{message_log.meta_message_id}:retry_count"

    case Redix.command(:redix, ["GET", retry_key]) do
      {:ok, nil} ->
        # First retry
        do_requeue(message_log, active_phone_id, campaign_id, retry_key, 1)

      {:ok, count_str} ->
        count = String.to_integer(count_str)

        if count < @max_retry_count do
          do_requeue(message_log, active_phone_id, campaign_id, retry_key, count + 1)
        else
          Logger.warning(
            "RetryManager: Message #{message_log.meta_message_id} exceeded max retries (#{@max_retry_count})"
          )

          :skip
        end

      _ ->
        :skip
    end
  end

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

  defp normalize_message_log(%MessageLog{} = log), do: {:ok, log}

  defp normalize_message_log(%{meta_message_id: meta_message_id})
       when is_binary(meta_message_id) do
    fetch_message_log(meta_message_id)
  end

  defp normalize_message_log(%{"meta_message_id" => meta_message_id})
       when is_binary(meta_message_id) do
    fetch_message_log(meta_message_id)
  end

  defp normalize_message_log(_), do: {:error, :invalid_message_log}

  defp fetch_message_log(meta_message_id) do
    case Repo.get_by(MessageLog, meta_message_id: meta_message_id) do
      nil -> {:error, :not_found}
      log -> {:ok, log}
    end
  end

  defp do_requeue(message_log, active_phone_id, campaign_id, retry_key, retry_count) do
    # Fetch contact to get original variables for retry
    contact = Repo.get(TitanFlow.Contacts.Contact, message_log.contact_id)
    variables = if contact, do: contact.variables || %{}, else: %{}

    payload =
      Jason.encode!(%{
        "phone" => message_log.recipient_phone,
        "contact_id" => message_log.contact_id,
        "name" => if(contact, do: contact.name, else: nil),
        "variables" => variables,
        "campaign_id" => campaign_id,
        "retry_count" => retry_count
      })

    queue_name = "queue:sending:#{campaign_id}:#{active_phone_id}"

    case Redix.command(:redix, ["RPUSH", queue_name, payload]) do
      {:ok, _} ->
        # Increment retry count with 2 hour expiry
        Redix.command(:redix, ["SETEX", retry_key, 7200, to_string(retry_count)])

        # Update message status to "retrying"
        # IMPORTANT: Fix status so it doesn't count as failure anymore
        message_log
        |> MessageLog.changeset(%{status: "retrying", error_code: nil})
        |> Repo.update()

        :ok

      {:error, reason} ->
        Logger.error("RetryManager: Failed to requeue message: #{inspect(reason)}")
        :skip
    end
  end
end
