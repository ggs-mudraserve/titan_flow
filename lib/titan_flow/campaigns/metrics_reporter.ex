defmodule TitanFlow.Campaigns.MetricsReporter do
  @moduledoc """
  Periodic metrics reporter GenServer.

  ## Responsibilities (5A + 6A)

  1. **Pool Health Monitoring** - Log Ecto pool stats every 30s
  2. **Queue Depth Monitoring** - Log Redis queue depths for running campaigns
  3. **Buffer Status** - Log LogBatcher buffer sizes
  4. **Performance Summary** - Log MPS and send rates

  ## Output

  Logs a compact status line every 30 seconds:
  ```
  [METRICS] Pool: 5/30 used, Q: 12ms | Queues: 5420 | MPS: 245 | Buffer: 1200
  ```
  """

  use GenServer
  require Logger

  @report_interval_ms 30_000
  @pool_alert_threshold_ms 5_000

  # Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get current metrics snapshot.
  """
  def get_metrics do
    GenServer.call(__MODULE__, :get_metrics)
  end

  # GenServer Callbacks

  @impl true
  def init(_opts) do
    Logger.info("MetricsReporter started, reporting every #{@report_interval_ms}ms")
    schedule_report()
    {:ok, %{last_sent_count: 0, last_report_time: System.monotonic_time(:second)}}
  end

  @impl true
  def handle_info(:report, state) do
    new_state = collect_and_report(state)
    schedule_report()
    {:noreply, new_state}
  end

  @impl true
  def handle_call(:get_metrics, _from, state) do
    metrics = collect_metrics()
    {:reply, metrics, state}
  end

  # Private Functions

  defp schedule_report do
    Process.send_after(self(), :report, @report_interval_ms)
  end

  defp collect_and_report(state) do
    metrics = collect_metrics()

    # Calculate MPS (messages per second since last report)
    now = System.monotonic_time(:second)
    elapsed_seconds = max(now - state.last_report_time, 1)
    total_sent = metrics.total_sent
    mps = div(total_sent - state.last_sent_count, elapsed_seconds)

    # Log compact status line
    log_status(metrics, mps)

    # Check for pool saturation (6A)
    if metrics.pool_queue_time_ms > @pool_alert_threshold_ms do
      TitanFlow.Campaigns.Metrics.alert_pool_saturation(metrics.pool_queue_time_ms)
    end

    %{state | last_sent_count: total_sent, last_report_time: now}
  end

  defp collect_metrics do
    %{
      pool_usage: get_pool_usage(),
      pool_queue_time_ms: get_avg_queue_time(),
      total_queue_depth: get_total_queue_depth(),
      log_buffer_size: get_log_buffer_size(),
      total_sent: get_total_sent(),
      running_campaigns: get_running_campaign_count()
    }
  end

  defp log_status(metrics, mps) do
    pool_str = "#{metrics.pool_usage.busy}/#{metrics.pool_usage.size}"

    Logger.info(
      "[METRICS] Pool: #{pool_str} busy, Q: #{metrics.pool_queue_time_ms}ms | " <>
        "Queues: #{metrics.total_queue_depth} | MPS: #{mps} | " <>
        "Buffer: #{metrics.log_buffer_size} | Campaigns: #{metrics.running_campaigns}"
    )
  end

  # Metric Collection Functions

  defp get_pool_usage do
    # Ecto doesn't expose pool stats directly, estimate from DBConnection
    # For now, return placeholder - actual implementation depends on pool type
    %{busy: 0, size: 30, idle: 30}
  end

  defp get_avg_queue_time do
    # This would come from telemetry events - placeholder for now
    # In real implementation, we'd track this via telemetry handler
    0
  end

  defp get_total_queue_depth do
    # Sum queue depths across all campaign:phone combinations
    keys = scan_keys("queue:sending:*")

    if length(keys) > 0 do
      keys
      |> Enum.map(fn key ->
        case Redix.command(:redix, ["LLEN", key]) do
          {:ok, len} when is_integer(len) -> len
          _ -> 0
        end
      end)
      |> Enum.sum()
    else
      0
    end
  end

  defp get_log_buffer_size do
    message_logs =
      case Redix.command(:redix, ["LLEN", "buffer:message_logs"]) do
        {:ok, len} when is_integer(len) -> len
        _ -> 0
      end

    contact_history =
      case Redix.command(:redix, ["LLEN", "buffer:contact_history"]) do
        {:ok, len} when is_integer(len) -> len
        _ -> 0
      end

    contact_status =
      case Redix.command(:redix, ["LLEN", "buffer:contact_status"]) do
        {:ok, len} when is_integer(len) -> len
        _ -> 0
      end

    message_logs + contact_history + contact_status
  end

  defp get_total_sent do
    # Sum sent counts across all running campaigns
    keys = scan_keys("campaign:*:sent_count")

    keys
    |> Enum.map(fn key ->
      case Redix.command(:redix, ["GET", key]) do
        {:ok, nil} -> 0
        {:ok, val} -> String.to_integer(val)
        _ -> 0
      end
    end)
    |> Enum.sum()
  end

  defp get_running_campaign_count do
    import Ecto.Query

    TitanFlow.Repo.aggregate(
      from(c in "campaigns", where: c.status == "running"),
      :count
    )
  rescue
    _ -> 0
  end

  defp scan_keys(pattern, count \\ 1000) do
    scan_keys("0", pattern, count, [])
  end

  defp scan_keys(cursor, pattern, count, acc) do
    case Redix.command(:redix, ["SCAN", cursor, "MATCH", pattern, "COUNT", count]) do
      {:ok, [next_cursor, keys]} when is_list(keys) ->
        new_acc = acc ++ keys

        if next_cursor == "0" do
          new_acc
        else
          scan_keys(next_cursor, pattern, count, new_acc)
        end

      _ ->
        acc
    end
  end
end
