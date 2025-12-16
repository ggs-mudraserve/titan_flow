defmodule TitanFlow.WhatsApp.RateLimiter do
  @moduledoc """
  Adaptive rate limiter GenServer for WhatsApp message sending.

  Manages per-phone-number rate limiting with dynamic MPS adjustment
  based on API response headers (x-rate-limit-remaining).

  ## Features
  - One GenServer per phone_number_id
  - Uses Hammer for local rate limiting
  - Dynamically adjusts MPS based on API feedback
  - Throttles down when approaching limits, throttles up when headroom available
  """

  use GenServer

  alias TitanFlow.WhatsApp.Client

  @default_mps 80
  @min_mps 10
  @max_mps 500

  # Thresholds for adjusting rate
  @throttle_down_threshold 20
  @throttle_up_threshold 80

  # Adjustment amounts
  @throttle_down_amount 10
  @throttle_up_amount 5

  # Client API

  @doc """
  Start a rate limiter for a specific phone number.

  ## Options
  - `:phone_number_id` - Required. WhatsApp phone number ID
  - `:access_token` - Required. API access token
  - `:initial_mps` - Optional. Starting messages per second (default: 80)
  """
  def start_link(opts) do
    phone_number_id = Keyword.fetch!(opts, :phone_number_id)
    name = via_tuple(phone_number_id)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Dispatch a template message through the rate limiter.

  ## Parameters
  - `phone_number_id` - The phone number ID (identifies the GenServer)
  - `message` - Map with `:to_phone`, `:template_name`, `:language_code`, `:components`

  ## Returns
  - `{:ok, :allowed}` - Rate limit check passed, caller can proceed with HTTP call
  - `{:error, :rate_limited}` - Rate limit exceeded, caller should retry later
  """
  def dispatch(phone_number_id, _message) do
    # Check if RateLimiter is running, start on-demand if not
    case Registry.lookup(TitanFlow.WhatsApp.RateLimiterRegistry, phone_number_id) do
      [] ->
        # Not running - try to start it
        case start_on_demand(phone_number_id) do
          {:ok, _pid} ->
            GenServer.call(via_tuple(phone_number_id), :check_rate, 5_000)
          {:error, reason} ->
            {:error, {:rate_limiter_start_failed, reason}}
        end
      _ ->
        GenServer.call(via_tuple(phone_number_id), :check_rate, 5_000)
    end
  end

  @doc """
  Get the access token for making HTTP calls.
  """
  def get_access_token(phone_number_id) do
    GenServer.call(via_tuple(phone_number_id), :get_access_token, 5_000)
  end

  @doc """
  Update stats from response headers (called by Pipeline after HTTP call).
  Used for throttle up/down logic.
  """
  def update_stats(phone_number_id, headers) do
    GenServer.cast(via_tuple(phone_number_id), {:update_stats, headers})
  end

  @doc """
  Notify RateLimiter of a 429 error (called by Pipeline).
  """
  def notify_rate_limited(phone_number_id) do
    GenServer.cast(via_tuple(phone_number_id), :rate_limited_429)
  end

  defp start_on_demand(phone_number_id) do
    # Lookup phone number to get access token
    case TitanFlow.WhatsApp.get_by_phone_number_id(phone_number_id) do
      nil ->
        {:error, :phone_not_found}
      phone ->
        DynamicSupervisor.start_child(
          TitanFlow.PhoneSupervisor,
          {__MODULE__, phone_number_id: phone_number_id, access_token: phone.access_token}
        )
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

  # Server Callbacks

  @impl true
  def init(opts) do
    phone_number_id = Keyword.fetch!(opts, :phone_number_id)
    access_token = Keyword.fetch!(opts, :access_token)
    initial_mps = Keyword.get(opts, :initial_mps, @default_mps)

    state = %{
      phone_number_id: phone_number_id,
      access_token: access_token,
      current_mps: initial_mps,
      status: :active
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:check_rate, _from, %{status: :paused} = state) do
    {:reply, {:error, :rate_limited}, state}
  end

  def handle_call(:check_rate, _from, state) do
    bucket_key = "send:#{state.phone_number_id}"

    # Check rate limit using Hammer - fast, non-blocking
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
  def handle_info(:resume_after_pause, state) do
    # Resume at reduced rate for safety
    safe_mps = max(div(state.current_mps, 2), @min_mps)
    {:noreply, %{state | status: :active, current_mps: safe_mps}}
  end

  @impl true
  def handle_cast({:set_mps, new_mps}, state) do
    clamped_mps = clamp(new_mps, @min_mps, @max_mps)
    {:noreply, %{state | current_mps: clamped_mps}}
  end

  @impl true
  def handle_cast({:update_stats, headers}, state) do
    # Analyze headers and potentially adjust rate
    new_state = analyze_and_adjust(headers, state)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:rate_limited_429, state) do
    # 429 Too Many Requests - Cooling off period
    Process.send_after(self(), :resume_after_pause, 15_000)
    {:noreply, %{state | status: :paused}}
  end

  # Private Functions

  defp send_message(message, state) do
    %{
      to_phone: to_phone,
      template_name: template_name,
      language_code: language_code,
      components: components
    } = message

    credentials = %{
      access_token: state.access_token,
      phone_number_id: state.phone_number_id
    }

    Client.send_template(to_phone, template_name, language_code, components, credentials)
  end

  defp analyze_and_adjust(headers, state) do
    rate_info = Client.parse_rate_limit_headers(headers)
    remaining = rate_info.remaining

    cond do
      is_nil(remaining) ->
        state

      # Brake (Safety): Remaining < 20%
      remaining < 20 ->
        # Decrease concurrency immediately
        new_mps = max(state.current_mps - @throttle_down_amount, @min_mps)
        %{state | current_mps: new_mps}

      # Accelerator (Speed): Remaining > 80%
      # Note: We should ideally also check if our queue is full, but strictly based on headers:
      remaining > 80 ->
        new_mps = min(state.current_mps + @throttle_up_amount, @max_mps)
        %{state | current_mps: new_mps}

      true ->
        state
    end
  end

  defp via_tuple(phone_number_id) do
    {:via, Registry, {TitanFlow.WhatsApp.RateLimiterRegistry, phone_number_id}}
  end

  defp clamp(value, min_val, max_val) do
    value
    |> max(min_val)
    |> min(max_val)
  end
end
