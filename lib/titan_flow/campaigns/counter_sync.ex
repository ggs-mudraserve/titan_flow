defmodule TitanFlow.Campaigns.CounterSync do
  @moduledoc """
  Periodic Redis-to-Postgres counter synchronization for running campaigns.
  
  This GenServer runs every 5 minutes and syncs campaign counters from Redis
  to Postgres for all running campaigns. This prevents data loss if Redis restarts.
  
  ## Design
  - Runs as part of the application supervision tree
  - Syncs all running campaigns every 5 minutes
  - Safe to run - uses atomic updates
  """

  use GenServer
  require Logger

  alias TitanFlow.Repo
  alias TitanFlow.Campaigns.Campaign

  import Ecto.Query

  # 5 minutes in milliseconds
  @sync_interval_ms 5 * 60 * 1000

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Force an immediate sync for all running campaigns.
  """
  def sync_now do
    GenServer.cast(__MODULE__, :sync_now)
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    Logger.info("CounterSync: Started - will sync running campaigns every 5 minutes")
    schedule_sync()
    {:ok, %{last_sync: nil, sync_count: 0}}
  end

  @impl true
  def handle_info(:sync, state) do
    sync_all_running_campaigns()
    schedule_sync()
    {:noreply, %{state | last_sync: DateTime.utc_now(), sync_count: state.sync_count + 1}}
  end

  @impl true
  def handle_cast(:sync_now, state) do
    sync_all_running_campaigns()
    {:noreply, %{state | last_sync: DateTime.utc_now(), sync_count: state.sync_count + 1}}
  end

  # Private Functions

  defp schedule_sync do
    Process.send_after(self(), :sync, @sync_interval_ms)
  end

  defp sync_all_running_campaigns do
    # Get all running campaigns
    running_campaigns = Repo.all(
      from c in Campaign,
      where: c.status == "running",
      select: c.id
    )

    if length(running_campaigns) > 0 do
      Logger.info("CounterSync: Syncing #{length(running_campaigns)} running campaign(s)")
      
      Enum.each(running_campaigns, fn campaign_id ->
        sync_campaign_counters(campaign_id)
      end)
      
      Logger.info("CounterSync: Sync complete")
    end
  end

  defp sync_campaign_counters(campaign_id) do
    # Get current Redis counts
    case Redix.pipeline(:redix, [
      ["GET", "campaign:#{campaign_id}:sent_count"],
      ["GET", "campaign:#{campaign_id}:delivered_count"],
      ["GET", "campaign:#{campaign_id}:read_count"],
      ["GET", "campaign:#{campaign_id}:replied_count"],
      ["GET", "campaign:#{campaign_id}:failed_count"]
    ]) do
      {:ok, results} ->
        [sent, delivered, read, replied, failed] = Enum.map(results, &to_int/1)
        
        # Only update if we have actual counts
        if sent > 0 or delivered > 0 or failed > 0 do
          from(c in Campaign, where: c.id == ^campaign_id)
          |> Repo.update_all(set: [
            sent_count: sent,
            delivered_count: delivered,
            read_count: read,
            replied_count: replied,
            failed_count: failed
          ])
          
          Logger.debug("CounterSync: Campaign #{campaign_id} - sent=#{sent}, delivered=#{delivered}, failed=#{failed}")
        end
        
      {:error, reason} ->
        Logger.warning("CounterSync: Failed to read Redis counters for campaign #{campaign_id}: #{inspect(reason)}")
    end
  end

  defp to_int(nil), do: 0
  defp to_int(val) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> 0
    end
  end
  defp to_int(val) when is_integer(val), do: val
end
