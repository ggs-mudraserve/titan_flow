defmodule TitanFlow.Campaigns.TemplateRetryPipeline do
  @moduledoc """
  Dedicated retry pipeline for template webhook failures.

  Consumes retry jobs from Redis and requeues messages after marking
  templates exhausted. This keeps WebhookBatcher lightweight.
  """

  use Broadway

  alias Broadway.Message
  alias TitanFlow.Campaigns.{Pipeline, RetryManager}

  @queue_name "queue:template_retry"
  @batch_size 200
  @processor_concurrency 10

  def start_link(opts \\ []) do
    redix_config = Application.get_env(:titan_flow, :redix)
    batch_size = Keyword.get(opts, :batch_size, @batch_size)
    processor_concurrency = Keyword.get(opts, :concurrency, @processor_concurrency)

    Broadway.start_link(__MODULE__,
      name: __MODULE__,
      producer: [
        module:
          {TitanFlow.Campaigns.RedisProducer,
           redis_config: redix_config, list_name: @queue_name, batch_size: batch_size},
        concurrency: 1
      ],
      processors: [
        default: [concurrency: processor_concurrency]
      ]
    )
  end

  @impl true
  def handle_message(_processor, %Message{data: data} = message, _context) do
    case Jason.decode(data) do
      {:ok, payload} ->
        handle_payload(payload)
        message

      {:error, _reason} ->
        Message.failed(message, "invalid template retry payload")
    end
  end

  defp handle_payload(payload) do
    campaign_id = payload["campaign_id"]
    phone_number_id = payload["phone_number_id"]
    template_name = payload["template_name"]
    error_code = payload["error_code"]

    case Pipeline.handle_template_webhook_error(
           campaign_id,
           phone_number_id,
           template_name,
           error_code
         ) do
      {:ok, _template_id} ->
        RetryManager.retry_template_message(payload)

      _ ->
        :ok
    end
  end
end
