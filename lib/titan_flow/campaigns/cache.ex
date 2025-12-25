defmodule TitanFlow.Campaigns.Cache do
  @moduledoc """
  Redis cache for campaign runtime data.

  Provides fast Redis-based template status checks for the per-message fallback system.
  When a template is paused (via webhook), Pipeline skips it immediately.
  """

  @key_prefix "campaign"

  @doc """
  Clear the active template cache for a campaign.
  Called when campaign ends.
  """
  @spec clear_active_template(integer()) :: :ok | {:error, term()}
  def clear_active_template(campaign_id) do
    key = "#{@key_prefix}:#{campaign_id}:active_template"

    case Redix.command(:redix, ["DEL", key]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Mark a template as paused in Redis cache (fast lookup).
  Called by webhook handler when template status changes.
  TTL of 24h ensures stale entries are eventually cleaned up.
  """
  def mark_template_paused(template_name) do
    key = "template:#{template_name}:status"

    case Redix.command(:redix, ["SET", key, "PAUSED", "EX", 86400]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Check if a template is marked as paused in cache.
  Returns true if paused, false otherwise.
  Called by Pipeline before each message send attempt.
  """
  def is_template_paused?(template_name) do
    key = "template:#{template_name}:status"

    case Redix.command(:redix, ["GET", key]) do
      {:ok, "PAUSED"} -> true
      _ -> false
    end
  end

  @doc """
  Clear template paused status (when it becomes active again).
  """
  def clear_template_paused(template_name) do
    key = "template:#{template_name}:status"
    Redix.command(:redix, ["DEL", key])
    :ok
  end
end
