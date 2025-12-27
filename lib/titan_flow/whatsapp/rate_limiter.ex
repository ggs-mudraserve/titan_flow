defmodule TitanFlow.WhatsApp.RateLimiter do
  @moduledoc """
  Per-phone rate limiter GenServer for WhatsApp message sending.

  Uses the configured `max_mps` (Messages Per Second) setting.
  Handles 429 errors with a 10-second cooldown period.

  ## Features
  - One GenServer per phone_number_id
  - Uses Hammer for local rate limiting
  - Respects configured MPS (10-500)
  - Pauses for 10s on 429 errors, then resumes at half-speed
  """

  use GenServer
  require Logger

  @min_mps 10
  @max_mps 500
  @default_mps 80
  @pause_duration_ms 10_000
  @spam_pause_duration_ms 60_000

  # Client API

  @doc """
  Start a rate limiter for a specific phone number.

  ## Options
  - `:phone_number_id` - Required. WhatsApp phone number ID
  - `:access_token` - Required. API access token
  - `:max_mps` - Optional. Messages per second limit (default: 80)
  """
  def start_link(opts) do
    phone_number_id = Keyword.fetch!(opts, :phone_number_id)
    name = via_tuple(phone_number_id)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Check rate limit for sending a message.

  ## Returns
  - `{:ok, :allowed, access_token}` - Rate limit check passed
  - `{:error, :rate_limited}` - Rate limit exceeded
  """
  def dispatch(phone_number_id, _message) do
    case Registry.lookup(TitanFlow.WhatsApp.RateLimiterRegistry, phone_number_id) do
      [] ->
        case start_on_demand(phone_number_id) do
          {:ok, _pid} ->
            safe_check_rate(phone_number_id)

          {:error, reason} ->
            {:error, {:rate_limiter_start_failed, reason}}
        end

      _ ->
        safe_check_rate(phone_number_id)
    end
  end

  @doc """
  Get the access token for making HTTP calls.
  """
  def get_access_token(phone_number_id) do
    GenServer.call(via_tuple(phone_number_id), :get_access_token, 5_000)
  end

  @doc """
  Notify RateLimiter of a 429 error. Pauses for 10 seconds.
  """
  def notify_rate_limited(phone_number_id) do
    GenServer.cast(via_tuple(phone_number_id), :rate_limited_429)
  end

  @doc """
  Notify RateLimiter of a 131048 error. Pauses for 60 seconds.
  """
  def notify_spam_rate_limited(phone_number_id) do
    GenServer.cast(via_tuple(phone_number_id), :rate_limited_131048)
  end

  @doc """
  Pause a phone for a custom duration and resume at a specific MPS.
  """
  def pause_for(phone_number_id, reason, duration_ms, resume_mps) do
    case Registry.lookup(TitanFlow.WhatsApp.RateLimiterRegistry, phone_number_id) do
      [] ->
        case start_on_demand(phone_number_id) do
          {:ok, _pid} ->
            GenServer.cast(via_tuple(phone_number_id), {:pause_for, reason, duration_ms, resume_mps})
            :ok

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        GenServer.cast(via_tuple(phone_number_id), {:pause_for, reason, duration_ms, resume_mps})
        :ok
    end
  end

  @doc """
  Get current rate limiter state for monitoring.
  """
  def get_state(phone_number_id) do
    GenServer.call(via_tuple(phone_number_id), :get_state)
  end

  @doc """
  Manually adjust the MPS rate.
  """
  def set_mps(phone_number_id, new_mps) do
    GenServer.cast(via_tuple(phone_number_id), {:set_mps, new_mps})
  end

  # Removed: update_stats/2 - no longer used since we removed header parsing

  defp start_on_demand(phone_number_id) do
    case Process.whereis(TitanFlow.PhoneSupervisor) do
      nil ->
        Logger.error(
          "RateLimiter: PhoneSupervisor not running, cannot start limiter for #{phone_number_id}"
        )

        {:error, :phone_supervisor_down}

      _pid ->
        case TitanFlow.WhatsApp.get_by_phone_number_id(phone_number_id) do
          nil ->
            {:error, :phone_not_found}

          phone ->
            try do
              DynamicSupervisor.start_child(
                TitanFlow.PhoneSupervisor,
                {__MODULE__,
                 phone_number_id: phone_number_id,
                 access_token: phone.access_token,
                 max_mps: @default_mps}
              )
            catch
              :exit, reason ->
                Logger.error(
                  "RateLimiter: Failed to start limiter for #{phone_number_id}: #{inspect(reason)}"
                )

                {:error, {:start_failed, reason}}
            end
        end
    end
  end

  defp safe_check_rate(phone_number_id) do
    try do
      GenServer.call(via_tuple(phone_number_id), :check_rate, 5_000)
    catch
      :exit, reason ->
        Logger.error(
          "RateLimiter: check_rate failed for #{phone_number_id}: #{inspect(reason)}"
        )

        {:error, {:rate_limiter_down, reason}}
    end
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    phone_number_id = Keyword.fetch!(opts, :phone_number_id)
    access_token = Keyword.fetch!(opts, :access_token)
    max_mps = Keyword.get(opts, :max_mps, @default_mps) |> clamp(@min_mps, @max_mps)

    Logger.info("RateLimiter started for #{phone_number_id} at #{max_mps} MPS")

    state = %{
      phone_number_id: phone_number_id,
      access_token: access_token,
      current_mps: max_mps,
      # Remember original config for resume
      configured_mps: max_mps,
      status: :active,
      pause_reason: nil,
      paused_until: nil,
      resume_mps: nil
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:check_rate, _from, %{status: :paused} = state) do
    {:reply, {:error, :rate_limited}, state}
  end

  def handle_call(:check_rate, _from, state) do
    bucket_key = "send:#{state.phone_number_id}"

    case Hammer.check_rate(bucket_key, 1000, state.current_mps) do
      {:allow, _count} ->
        {:reply, {:ok, :allowed, state.access_token}, state}

      {:deny, _limit} ->
        {:reply, {:error, :rate_limited}, state}
    end
  end

  @impl true
  def handle_call(:get_access_token, _from, state) do
    {:reply, {:ok, state.access_token}, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_cast({:set_mps, new_mps}, state) do
    clamped_mps = clamp(new_mps, @min_mps, @max_mps)

    Logger.info(
      "RateLimiter #{state.phone_number_id}: MPS changed #{state.current_mps} -> #{clamped_mps}"
    )

    {:noreply, %{state | current_mps: clamped_mps, configured_mps: clamped_mps}}
  end

  @impl true
  def handle_cast(:rate_limited_429, state) do
    Logger.warning(
      "RateLimiter #{state.phone_number_id}: 429 received, pausing for #{@pause_duration_ms}ms"
    )

    safe_mps = max(div(state.configured_mps, 2), @min_mps)
    {:noreply, pause(state, :rate_limited_429, @pause_duration_ms, safe_mps)}
  end

  @impl true
  def handle_cast(:rate_limited_131048, state) do
    Logger.warning(
      "RateLimiter #{state.phone_number_id}: 131048 received, pausing for #{@spam_pause_duration_ms}ms"
    )

    {:noreply, pause(state, :rate_limited_131048, @spam_pause_duration_ms, state.configured_mps)}
  end

  @impl true
  def handle_cast({:pause_for, reason, duration_ms, resume_mps}, state) do
    clamped_mps = clamp(resume_mps, @min_mps, @max_mps)

    Logger.warning(
      "RateLimiter #{state.phone_number_id}: Paused for #{duration_ms}ms (#{inspect(reason)})"
    )

    {:noreply, pause(state, reason, duration_ms, clamped_mps)}
  end

  @impl true
  def handle_info({:resume_after_pause, reason}, state) do
    now_ms = System.monotonic_time(:millisecond)

    cond do
      state.status != :paused ->
        {:noreply, state}

      state.pause_reason != reason ->
        {:noreply, state}

      state.paused_until && now_ms < state.paused_until ->
        {:noreply, state}

      true ->
        resume_mps = state.resume_mps || state.current_mps

        Logger.info(
          "RateLimiter #{state.phone_number_id}: Resuming at #{resume_mps} MPS (was #{state.configured_mps})"
        )

        {:noreply,
         %{
           state
           | status: :active,
             current_mps: resume_mps,
             pause_reason: nil,
             paused_until: nil,
             resume_mps: nil
         }}
    end
  end

  # Private Functions

  defp via_tuple(phone_number_id) do
    {:via, Registry, {TitanFlow.WhatsApp.RateLimiterRegistry, phone_number_id}}
  end

  defp pause(state, reason, duration_ms, resume_mps) do
    paused_until = System.monotonic_time(:millisecond) + duration_ms
    Process.send_after(self(), {:resume_after_pause, reason}, duration_ms)

    %{
      state
      | status: :paused,
        pause_reason: reason,
        paused_until: paused_until,
        resume_mps: resume_mps
    }
  end

  defp clamp(value, min_val, max_val) do
    value
    |> max(min_val)
    |> min(max_val)
  end
end
