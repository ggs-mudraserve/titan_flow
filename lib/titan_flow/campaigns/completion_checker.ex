defmodule TitanFlow.Campaigns.CompletionChecker do
  @moduledoc """
  P1 FIX: Debounced campaign completion checker.

  Instead of checking completion on every webhook (which triggers heavy DB queries),
  this GenServer checks running campaigns every 30 seconds.

  This reduces DB load from O(webhooks) to O(running_campaigns * checks_per_minute).
  """
  use GenServer
  require Logger

  alias TitanFlow.Campaigns
  alias TitanFlow.Campaigns.MessageTracking

  # 30 seconds
  @check_interval_ms 30_000

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # --- Server Callbacks ---

  @impl true
  def init(_opts) do
    Logger.info("CompletionChecker started, checking every #{@check_interval_ms}ms")
    schedule_check()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:check, state) do
    check_running_campaigns()
    schedule_check()
    {:noreply, state}
  end

  # --- Private Functions ---

  defp schedule_check do
    Process.send_after(self(), :check, @check_interval_ms)
  end

  defp check_running_campaigns do
    # Get all running campaigns
    running_campaigns = Campaigns.list_campaigns_by_status("running")

    if length(running_campaigns) > 0 do
      Logger.debug("CompletionChecker: Checking #{length(running_campaigns)} running campaigns")
    end

    Enum.each(running_campaigns, fn campaign ->
      # Check completion for each running campaign
      # This will sync counters and mark complete if conditions met
      MessageTracking.check_campaign_completion(campaign.id)
    end)
  end
end
