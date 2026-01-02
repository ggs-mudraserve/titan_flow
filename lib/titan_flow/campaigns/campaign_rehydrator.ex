defmodule TitanFlow.Campaigns.CampaignRehydrator do
  @moduledoc """
  Rehydrates running campaigns after an app restart by restarting pipelines
  and buffer managers.
  """

  use GenServer
  require Logger

  alias TitanFlow.Campaigns
  alias TitanFlow.Campaigns.Orchestrator

  @rehydrate_delay_ms 5_000
  @retry_delay_ms 15_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Logger.info(
      "CampaignRehydrator started, rehydrating running campaigns in #{@rehydrate_delay_ms}ms"
    )

    Process.send_after(self(), :rehydrate, @rehydrate_delay_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:rehydrate, state) do
    case rehydrate_running_campaigns() do
      :ok ->
        {:noreply, state}

      {:error, _reason} ->
        Logger.warning("CampaignRehydrator: Retry in #{@retry_delay_ms}ms")
        Process.send_after(self(), :rehydrate, @retry_delay_ms)
        {:noreply, state}
    end
  end

  defp rehydrate_running_campaigns do
    running_campaigns = Campaigns.list_campaigns_by_status("running")

    case running_campaigns do
      [] ->
        Logger.info("CampaignRehydrator: No running campaigns to rehydrate")
        :ok

      campaigns ->
        Logger.info("CampaignRehydrator: Rehydrating #{length(campaigns)} running campaign(s)")

        Enum.each(campaigns, fn campaign ->
          case Orchestrator.resume_campaign(campaign.id) do
            {:ok, result} ->
              Logger.info("CampaignRehydrator: Campaign #{campaign.id} #{result}")

            {:error, reason} ->
              Logger.error(
                "CampaignRehydrator: Failed to rehydrate campaign #{campaign.id}: #{inspect(reason)}"
              )
          end
        end)

        :ok
    end
  rescue
    e ->
      Logger.error("CampaignRehydrator: Failed to rehydrate campaigns: #{Exception.message(e)}")
      {:error, e}
  end
end
