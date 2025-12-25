defmodule TitanFlow.Campaigns.QualityMonitor do
  @moduledoc """
  Monitors template quality and marks templates as paused.

  When a "Template Paused" webhook arrives, this module marks the template
  status in Redis. The Pipeline checks this before each message and skips
  paused templates, trying the next in the fallback list.
  """

  require Logger

  alias TitanFlow.Campaigns
  alias TitanFlow.Campaigns.Cache
  alias TitanFlow.Templates

  @doc """
  Handle template degradation events from webhooks.
  Marks the template as paused so Pipeline will skip it.

  ## Events that trigger marking as paused:
  - "PAUSED" - Template paused by Meta
  - "FLAGGED" - Template flagged for review
  - "DISABLED" - Template disabled
  - "REJECTED" - Template rejected
  - "MARKETING" - Category changed to MARKETING (utility campaigns can't use)
  """
  @spec handle_template_degradation(integer(), String.t()) :: :ok
  def handle_template_degradation(template_id, event_type) do
    if should_pause?(event_type) do
      template = Templates.get_template!(template_id)
      Cache.mark_template_paused(template.name)

      Logger.warning(
        "QualityMonitor: Template #{template.name} (ID: #{template_id}) marked PAUSED due to #{event_type}"
      )

      check_affected_campaigns(template, event_type)
    end

    :ok
  end

  @doc """
  Alias for backwards compatibility - calls handle_template_degradation.
  """
  @spec switch_template(integer()) :: :ok
  def switch_template(template_id) do
    handle_template_degradation(template_id, "DEGRADED")
  end

  @doc """
  Clear paused status for a template (when it becomes approved again).
  """
  @spec clear_template_paused(String.t()) :: :ok
  def clear_template_paused(template_name) do
    Cache.clear_template_paused(template_name)
    Logger.info("QualityMonitor: Template #{template_name} paused status cleared")
    :ok
  end

  # Private Functions

  defp should_pause?(event_type) do
    event_type in ["PAUSED", "FLAGGED", "DISABLED", "REJECTED", "MARKETING", "DEGRADED"]
  end

  defp check_affected_campaigns(template, event_type) do
    alias TitanFlow.Campaigns.Orchestrator

    # Find running campaigns using this template as primary
    campaigns = Campaigns.list_campaigns()

    affected_campaigns =
      Enum.filter(campaigns, fn campaign ->
        campaign.status in ["running", "importing", "ready"] and
          campaign.primary_template_id == template.id
      end)

    # Log warning for affected campaigns - Pipeline will handle fallback
    for campaign <- affected_campaigns do
      if campaign.fallback_template_id do
        Logger.warning(
          "Campaign #{campaign.id}: Primary template #{template.name} degraded (#{event_type}). Pipeline will use fallback."
        )
      else
        # No fallback configured - pause the campaign
        Logger.warning(
          "Campaign #{campaign.id}: Primary template degraded with NO FALLBACK - pausing campaign"
        )

        Orchestrator.pause_campaign(campaign.id)
      end
    end

    Logger.info(
      "QualityMonitor: #{length(affected_campaigns)} campaigns affected by template #{template.name} degradation"
    )
  end
end
