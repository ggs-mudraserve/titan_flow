defmodule TitanFlow.Campaigns.AutoScaler do
  @moduledoc """
  Dynamic MPS adjustment based on queue depth and DB load (Phase 3: 7B + 7C).

  ## Strategy

  1. **Queue-Depth Scaling (7B)**: Monitor Redis queue depths per phone
     - High queue (>15K): Increase MPS to drain faster
     - Low queue (<2K): Decrease MPS to conserve resources
     
  2. **DB Load Throttling (7C)**: Monitor pool saturation
     - If pool checkout time exceeds threshold, throttle all phones

  ## MPS Tiers

  | Queue Depth | Target MPS | Reason |
  |-------------|------------|--------|
  | > 15,000 | 200 | Aggressive drain |
  | > 10,000 | 150 | Fast processing |
  | > 5,000 | 100 | Normal operation |
  | < 2,000 | 80 | Conservative |
  | (DB overload) | 50 | Emergency throttle |
  """

  use GenServer
  require Logger

  alias TitanFlow.WhatsApp.RateLimiter

  # Check every 10 seconds
  @check_interval_ms 10_000
  # MPS tiers based on queue depth
  @queue_tiers [
    # Very high queue -> aggressive
    {15_000, 200},
    # High queue -> fast
    {10_000, 150},
    # Medium queue -> normal
    {5_000, 100},
    # Low queue -> conservative
    {0, 80}
  ]

  # When DB is overloaded
  @emergency_mps 50

  # Public API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get current scaling decisions for monitoring.
  """
  def get_state do
    GenServer.call(__MODULE__, :get_state)
  end

  @doc """
  Force an immediate scaling check.
  """
  def check_now do
    GenServer.cast(__MODULE__, :check_now)
  end

  # GenServer Callbacks

  @impl true
  def init(_opts) do
    Logger.info("AutoScaler started, checking every #{@check_interval_ms}ms")
    schedule_check()

    {:ok,
     %{
       last_check: nil,
       # phone_id => {current_mps, queue_depth}
       active_phones: %{},
       db_throttle_active: false
     }}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_cast(:check_now, state) do
    new_state = perform_scaling_check(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:check, state) do
    new_state = perform_scaling_check(state)
    schedule_check()
    {:noreply, new_state}
  end

  # Private Functions

  defp schedule_check do
    Process.send_after(self(), :check, @check_interval_ms)
  end

  defp perform_scaling_check(state) do
    # 1. Check DB load (7C)
    db_overloaded = check_db_load()

    # 2. Get active campaign queues
    queues = get_active_queues()

    # 3. Apply scaling decisions
    active_phones = apply_scaling_decisions(queues, db_overloaded)

    # 4. Log summary if any changes
    if map_size(active_phones) > 0 do
      Logger.debug(
        "[AutoScaler] Active phones: #{map_size(active_phones)}, DB throttle: #{db_overloaded}"
      )
    end

    %{
      state
      | last_check: System.monotonic_time(:second),
        active_phones: active_phones,
        db_throttle_active: db_overloaded
    }
  end

  defp check_db_load do
    # Check if we have pool saturation alerts recently
    # This is a simple implementation - could be enhanced with actual metrics
    # For now, we check Redis for a saturation flag
    case Redix.command(:redix, ["GET", "autoscaler:db_throttle"]) do
      {:ok, "1"} -> true
      _ -> false
    end
  end

  defp get_active_queues do
    case Redix.command(:redix, ["KEYS", "queue:sending:*"]) do
      {:ok, keys} when is_list(keys) ->
        keys
        |> Enum.map(&parse_queue_key/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.map(fn {campaign_id, phone_id, key} ->
          depth = get_queue_depth(key)
          {phone_id, %{campaign_id: campaign_id, depth: depth}}
        end)
        |> Enum.into(%{})

      _ ->
        %{}
    end
  end

  defp parse_queue_key(key) do
    case String.split(key, ":") do
      ["queue", "sending", campaign_id, phone_id] ->
        {String.to_integer(campaign_id), phone_id, key}

      _ ->
        nil
    end
  end

  defp get_queue_depth(key) do
    case Redix.command(:redix, ["LLEN", key]) do
      {:ok, len} when is_integer(len) -> len
      _ -> 0
    end
  end

  defp apply_scaling_decisions(queues, db_overloaded) do
    Enum.map(queues, fn {phone_id, %{depth: depth}} ->
      target_mps =
        if db_overloaded do
          @emergency_mps
        else
          calculate_target_mps(depth)
        end

      # Apply MPS adjustment via RateLimiter
      apply_mps_adjustment(phone_id, target_mps)

      {phone_id, %{mps: target_mps, depth: depth}}
    end)
    |> Enum.into(%{})
  end

  defp calculate_target_mps(queue_depth) do
    @queue_tiers
    |> Enum.find(fn {threshold, _mps} -> queue_depth >= threshold end)
    |> case do
      {_, mps} -> mps
      # Default
      nil -> 80
    end
  end

  defp apply_mps_adjustment(phone_id, target_mps) do
    # Try to adjust the rate limiter for this phone
    # Note: This requires RateLimiter to support dynamic MPS adjustment
    try do
      RateLimiter.set_mps(phone_id, target_mps)
    rescue
      # RateLimiter might not exist or support this
      _ -> :ok
    catch
      :exit, _ -> :ok
    end
  end
end
