defmodule TitanFlow.Campaigns.QualityMonitor do
  @moduledoc """
  Monitors template quality and switches to fallback when needed.
  
  When a "Template Paused" or "Low Quality" webhook arrives,
  this module updates the Redis cache to the fallback template,
  allowing all 50 concurrent workers to instantly switch without stopping.
  """

  require Logger

  alias TitanFlow.Campaigns
  alias TitanFlow.Campaigns.Cache
  alias TitanFlow.Templates

  @doc """
  Check if template switch is needed based on webhook event.
  
  ## Events that trigger a switch:
  - "PAUSED" - Template paused by Meta
  - "FLAGGED" - Template flagged for review
  - "DISABLED" - Template disabled
  
  ## Parameters
  - `campaign_id` - The campaign to potentially switch
  - `event_type` - The webhook event type (e.g., "PAUSED", "FLAGGED")
  - `template_name` - The affected template name (optional, for verification)
  """
  @spec switch_template_if_needed(integer(), String.t(), String.t() | nil) :: :ok | {:error, term()}
  def switch_template_if_needed(campaign_id, event_type, template_name \\ nil) do
    if should_switch?(event_type) do
      do_switch_to_fallback(campaign_id, template_name)
    else
      :ok
    end
  end

  @doc """
  Force switch to fallback template for a campaign.
  """
  @spec switch_to_fallback(integer()) :: :ok | {:error, term()}
  def switch_to_fallback(campaign_id) do
    do_switch_to_fallback(campaign_id, nil)
  end

  @doc """
  Handle template degradation - find all running campaigns using this template
  and switch to fallback or pause if no fallback available.
  
  Called by WebhookController when template status/category changes.
  """
  @spec switch_template(integer()) :: :ok
  def switch_template(template_id) do
    alias TitanFlow.Campaigns.Orchestrator
    
    template = Templates.get_template!(template_id)
    Logger.warning("QualityMonitor: Template #{template.name} (ID: #{template_id}) degraded, checking affected campaigns")
    
    # Find all running campaigns using this template as primary
    campaigns = Campaigns.list_campaigns()
    
    affected_count = Enum.reduce(campaigns, 0, fn campaign, count ->
      is_affected = campaign.status in ["running", "importing", "ready"] and
                    campaign.primary_template_id == template_id
      
      if is_affected do
        handle_campaign_template_switch(campaign, template)
        count + 1
      else
        count
      end
    end)
    
    Logger.info("QualityMonitor: Processed #{affected_count} campaigns affected by template #{template.name}")
    :ok
  end

  defp handle_campaign_template_switch(campaign, degraded_template) do
    alias TitanFlow.Campaigns.Orchestrator
    
    if campaign.fallback_template_id do
      # Has fallback - switch to it
      fallback = Templates.get_template!(campaign.fallback_template_id)
      
      # Verify fallback is still valid
      if fallback.status == "APPROVED" do
        Cache.set_active_template(campaign.id, fallback.name, fallback.language || "en")
        Logger.warning("Campaign #{campaign.id}: Switched to Fallback due to Category Change (#{degraded_template.name} -> #{fallback.name})")
      else
        # Fallback also degraded - pause campaign
        Logger.warning("Campaign #{campaign.id}: Pausing - Primary and Fallback templates both degraded")
        Orchestrator.pause_campaign(campaign.id)
      end
    else
      # No fallback - pause campaign
      Logger.warning("Campaign #{campaign.id}: Paused Campaign - Primary Template degraded and no fallback available")
      Orchestrator.pause_campaign(campaign.id)
    end
  end

  @doc """
  Switch back to primary template for a campaign.
  """
  @spec switch_to_primary(integer()) :: :ok | {:error, term()}
  def switch_to_primary(campaign_id) do
    campaign = Campaigns.get_campaign!(campaign_id)

    if campaign.primary_template_id do
      template = Templates.get_template!(campaign.primary_template_id)
      Cache.set_active_template(campaign_id, template.name, template.language || "en")
      Logger.info("Campaign #{campaign_id}: Switched back to primary template #{template.name}")
      :ok
    else
      {:error, :no_primary_template}
    end
  end

  # Private Functions

  defp should_switch?(event_type) do
    # Switch if paused, disabled, rejected, OR if category changed to MARKETING
    event_type in ["PAUSED", "FLAGGED", "DISABLED", "REJECTED", "MARKETING"]
  end

  defp do_switch_to_fallback(campaign_id, affected_template_name) do
    campaign = Campaigns.get_campaign!(campaign_id)

    # Verify the affected template matches our primary (if provided)
    if affected_template_name do
      case Cache.get_active_template(campaign_id) do
        {:ok, %{template_name: current}} when current != affected_template_name ->
          # The affected template is not our current one, no action needed
          Logger.debug("Campaign #{campaign_id}: Affected template #{affected_template_name} is not current (#{current}), skipping")
          :ok
        _ ->
          do_fallback_switch(campaign)
      end
    else
      do_fallback_switch(campaign)
    end
  end

  defp do_fallback_switch(campaign) do
    if campaign.fallback_template_id do
      fallback = Templates.get_template!(campaign.fallback_template_id)
      
      case Cache.set_active_template(campaign.id, fallback.name, fallback.language || "en") do
        :ok ->
          Logger.warning(
            "Campaign #{campaign.id}: QUALITY EVENT - Switched to fallback template #{fallback.name}"
          )
          :ok

        {:error, reason} ->
          Logger.error(
            "Campaign #{campaign.id}: Failed to switch to fallback: #{inspect(reason)}"
          )
          {:error, reason}
      end
    else
      Logger.warning(
        "Campaign #{campaign.id}: Quality event received but no fallback template configured"
      )
      {:error, :no_fallback_template}
    end
  end
end
