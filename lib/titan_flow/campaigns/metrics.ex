defmodule TitanFlow.Campaigns.Metrics do
  @moduledoc """
  Campaign system telemetry and metrics.
  
  ## Emitted Events (5A)
  
  All events are prefixed with `[:titan_flow, :campaign, ...]`
  
  - `[:titan_flow, :campaign, :pipeline, :message_processed]`
    Measurements: %{duration: native_time}
    Metadata: %{campaign_id, phone_number_id, status}
    
  - `[:titan_flow, :campaign, :buffer, :refill]`
    Measurements: %{duration: native_time, count: integer}
    Metadata: %{campaign_id, phone_number_id}
    
  - `[:titan_flow, :campaign, :log_batcher, :flush]`
    Measurements: %{duration: native_time, count: integer}
    Metadata: %{buffer_type: :message_logs | :contact_history}
    
  - `[:titan_flow, :campaign, :queue, :depth]`
    Measurements: %{depth: integer}
    Metadata: %{campaign_id, phone_number_id}
  
  ## Connection Pool Metrics (6A)
  
  Ecto already emits queue_time and checkout metrics. We add visibility via:
  - Periodic pool status logging
  - Alert when pool is saturated (checkout > 5s)
  """
  
  require Logger
  
  @doc """
  Emit a metric for message processing in Pipeline.
  """
  def measure_message_processed(campaign_id, phone_number_id, status, fun) do
    start = System.monotonic_time()
    result = fun.()
    duration = System.monotonic_time() - start
    
    :telemetry.execute(
      [:titan_flow, :campaign, :pipeline, :message_processed],
      %{duration: duration},
      %{campaign_id: campaign_id, phone_number_id: phone_number_id, status: status}
    )
    
    result
  end
  
  @doc """
  Emit a metric for BufferManager refill operation.
  """
  def measure_buffer_refill(campaign_id, phone_number_id, fun) do
    start = System.monotonic_time()
    {count, result} = fun.()
    duration = System.monotonic_time() - start
    
    :telemetry.execute(
      [:titan_flow, :campaign, :buffer, :refill],
      %{duration: duration, count: count},
      %{campaign_id: campaign_id, phone_number_id: phone_number_id}
    )
    
    result
  end
  
  @doc """
  Emit a metric for LogBatcher flush operation.
  """
  def measure_log_flush(buffer_type, fun) do
    start = System.monotonic_time()
    count = fun.()
    duration = System.monotonic_time() - start
    
    :telemetry.execute(
      [:titan_flow, :campaign, :log_batcher, :flush],
      %{duration: duration, count: count},
      %{buffer_type: buffer_type}
    )
    
    count
  end
  
  @doc """
  Report current queue depth (called periodically).
  """
  def report_queue_depth(campaign_id, phone_number_id, depth) do
    :telemetry.execute(
      [:titan_flow, :campaign, :queue, :depth],
      %{depth: depth},
      %{campaign_id: campaign_id, phone_number_id: phone_number_id}
    )
  end
  
  @doc """
  Emit an alert for pool saturation (6A).
  """
  def alert_pool_saturation(checkout_time_ms) do
    Logger.error("[ALERT] DB Pool Saturation: checkout time #{checkout_time_ms}ms exceeds 5s threshold")
    
    :telemetry.execute(
      [:titan_flow, :campaign, :pool, :saturation],
      %{checkout_time_ms: checkout_time_ms},
      %{}
    )
  end
end
