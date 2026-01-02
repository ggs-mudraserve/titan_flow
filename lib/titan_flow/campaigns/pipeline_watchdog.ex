defmodule TitanFlow.Campaigns.PipelineWatchdog do
  @moduledoc """
  Detects stalled campaign pipelines and triggers a controlled restart.
  """

  use GenServer
  require Logger

  alias TitanFlow.Campaigns
  alias TitanFlow.Campaigns.Orchestrator
  alias TitanFlow.Repo
  alias TitanFlow.WhatsApp.PhoneNumber

  @check_interval_ms 30_000
  @stall_threshold_ms 90_000
  @restart_cooldown_ms 300_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Logger.info("PipelineWatchdog started, checking every #{@check_interval_ms}ms")
    schedule_check()
    {:ok, %{campaigns: %{}}}
  end

  @impl true
  def handle_info(:check, state) do
    new_state = check_campaigns(state)
    schedule_check()
    {:noreply, new_state}
  end

  defp schedule_check do
    Process.send_after(self(), :check, @check_interval_ms)
  end

  defp check_campaigns(state) do
    now_ms = System.monotonic_time(:millisecond)
    running_campaigns = Campaigns.list_campaigns_by_status("running")
    running_ids = MapSet.new(Enum.map(running_campaigns, & &1.id))

    campaigns_state =
      state.campaigns
      |> Enum.filter(fn {id, _} -> MapSet.member?(running_ids, id) end)
      |> Map.new()

    Enum.reduce(running_campaigns, %{state | campaigns: campaigns_state}, fn campaign, acc ->
      update_campaign_state(acc, campaign, now_ms)
    end)
  end

  defp update_campaign_state(state, campaign, now_ms) do
    if Orchestrator.is_paused?(campaign.id) do
      state
    else
      queue_depth = queue_depth(campaign)
      sent_count = get_sent_count(campaign.id, campaign.sent_count)

      prev =
        Map.get(state.campaigns, campaign.id, %{
          last_sent: sent_count,
          last_progress_at: now_ms,
          last_restart_at: nil,
          last_missing_restart_at: nil
        })

      missing_with_queue = missing_pipelines_with_queue(campaign)

      cond do
        sent_count > prev.last_sent ->
          put_campaign_state(state, campaign.id, %{
            last_sent: sent_count,
            last_progress_at: now_ms,
            last_restart_at: prev.last_restart_at,
            last_missing_restart_at: prev.last_missing_restart_at
          })

        queue_depth > 0 and stall_timeout?(prev, now_ms) and restart_allowed?(prev, now_ms) ->
          Logger.warning(
            "PipelineWatchdog: Campaign #{campaign.id} stalled (queue=#{queue_depth}, sent=#{sent_count}), restarting pipelines"
          )

          Task.start(fn -> Orchestrator.force_restart_pipelines(campaign.id) end)

          put_campaign_state(state, campaign.id, %{
            last_sent: sent_count,
            last_progress_at: now_ms,
            last_restart_at: now_ms,
            last_missing_restart_at: prev.last_missing_restart_at
          })

        missing_with_queue != [] and missing_restart_allowed?(prev, now_ms) ->
          Logger.warning(
            "PipelineWatchdog: Campaign #{campaign.id} missing pipelines for #{inspect(missing_with_queue)} with queued messages; restarting"
          )

          Task.start(fn -> Orchestrator.ensure_pipelines_running(campaign.id) end)

          put_campaign_state(state, campaign.id, %{
            last_sent: sent_count,
            last_progress_at: prev.last_progress_at,
            last_restart_at: prev.last_restart_at,
            last_missing_restart_at: now_ms
          })

        true ->
          state
      end
    end
  end

  defp put_campaign_state(state, campaign_id, data) do
    %{state | campaigns: Map.put(state.campaigns, campaign_id, data)}
  end

  defp stall_timeout?(prev, now_ms) do
    now_ms - prev.last_progress_at >= @stall_threshold_ms
  end

  defp restart_allowed?(prev, now_ms) do
    case prev.last_restart_at do
      nil -> true
      last_restart_at -> now_ms - last_restart_at >= @restart_cooldown_ms
    end
  end

  defp missing_restart_allowed?(prev, now_ms) do
    case prev.last_missing_restart_at do
      nil -> true
      last_restart_at -> now_ms - last_restart_at >= @restart_cooldown_ms
    end
  end

  defp missing_pipelines_with_queue(campaign) do
    campaign
    |> campaign_phone_number_ids()
    |> Enum.filter(fn phone_number_id ->
      queue_depth_for_phone(campaign.id, phone_number_id) > 0 and
        Registry.lookup(TitanFlow.Campaigns.PipelineRegistry, phone_number_id) == []
    end)
  end

  defp queue_depth(campaign) do
    campaign
    |> campaign_phone_number_ids()
    |> Enum.map(&queue_depth_for_phone(campaign.id, &1))
    |> Enum.sum()
  end

  defp queue_depth_for_phone(campaign_id, phone_number_id) do
    queue_name = "queue:sending:#{campaign_id}:#{phone_number_id}"

    case Redix.command(:redix, ["LLEN", queue_name]) do
      {:ok, len} when is_integer(len) -> len
      _ -> 0
    end
  end

  defp get_sent_count(campaign_id, fallback) do
    key = "campaign:#{campaign_id}:sent_count"

    case Redix.command(:redix, ["GET", key]) do
      {:ok, nil} -> fallback || 0
      {:ok, val} -> String.to_integer(val)
      _ -> fallback || 0
    end
  end

  defp campaign_phone_number_ids(campaign) do
    phone_ids =
      case campaign.senders_config do
        config when is_list(config) and length(config) > 0 ->
          config
          |> Enum.map(fn entry -> Map.get(entry, "phone_id") || Map.get(entry, :phone_id) end)

        _ ->
          campaign.phone_ids || []
      end

    phone_ids
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.reduce([], fn phone_id, acc ->
      case Repo.get(PhoneNumber, phone_id) do
        nil ->
          Logger.warning(
            "PipelineWatchdog: Phone #{phone_id} missing while checking campaign #{campaign.id}"
          )

          acc

        phone ->
          [phone.phone_number_id | acc]
      end
    end)
  end
end
