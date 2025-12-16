defmodule TitanFlow.Campaigns.Cache do
  @moduledoc """
  Redis cache for campaign runtime data.
  
  Enables late-binding template switching without stopping the campaign.
  All 50 concurrent workers can instantly switch to a new template when 
  quality drops by updating the Redis key.
  """

  @key_prefix "campaign"
  @template_suffix "active_template"

  @doc """
  Set the active template for a campaign.
  Called when campaign starts or when switching templates.
  """
  @spec set_active_template(integer(), String.t(), String.t()) :: :ok | {:error, term()}
  def set_active_template(campaign_id, template_name, language_code \\ "en") do
    key = template_key(campaign_id)
    value = Jason.encode!(%{template_name: template_name, language_code: language_code})

    case Redix.command(:redix, ["SET", key, value]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Get the active template for a campaign.
  Called by Pipeline before sending each message.
  """
  @spec get_active_template(integer()) :: {:ok, %{template_name: String.t(), language_code: String.t()}} | {:error, term()}
  def get_active_template(campaign_id) do
    key = template_key(campaign_id)

    case Redix.command(:redix, ["GET", key]) do
      {:ok, nil} ->
        {:error, :not_found}

      {:ok, value} ->
        case Jason.decode(value) do
          {:ok, %{"template_name" => name, "language_code" => lang}} ->
            {:ok, %{template_name: name, language_code: lang}}

          {:ok, %{"template_name" => name}} ->
            {:ok, %{template_name: name, language_code: "en"}}

          _ ->
            {:error, :invalid_format}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Clear the active template cache for a campaign.
  Called when campaign ends.
  """
  @spec clear_active_template(integer()) :: :ok | {:error, term()}
  def clear_active_template(campaign_id) do
    key = template_key(campaign_id)

    case Redix.command(:redix, ["DEL", key]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Set the list of available fallback templates for a campaign.
  Called when campaign starts. Stored as ordered list in Redis.
  """
  def set_fallback_templates(campaign_id, template_list) do
    key = "#{@key_prefix}:#{campaign_id}:fallback_templates"
    value = Jason.encode!(template_list)
    
    case Redix.command(:redix, ["SET", key, value]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Get the next available fallback template.
  Returns {:ok, template_info} or {:error, :no_fallback_available}
  """
  def get_next_fallback_template(campaign_id, current_template_name) do
    key = "#{@key_prefix}:#{campaign_id}:fallback_templates"
    
    case Redix.command(:redix, ["GET", key]) do
      {:ok, nil} -> 
        {:error, :no_fallback_available}
      
      {:ok, value} ->
        case Jason.decode(value) do
          {:ok, templates} when is_list(templates) ->
            # Find current template index and get next one
            current_idx = Enum.find_index(templates, fn t -> 
              t["name"] == current_template_name || t["template_name"] == current_template_name
            end)
            
            next_idx = if current_idx, do: current_idx + 1, else: 0
            
            if next_idx < length(templates) do
              next_template = Enum.at(templates, next_idx)
              {:ok, %{
                template_name: next_template["name"] || next_template["template_name"],
                language_code: next_template["language"] || next_template["language_code"] || "en"
              }}
            else
              {:error, :no_fallback_available}
            end
          
          _ -> {:error, :invalid_format}
        end
      
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Mark a template as paused in Redis cache (fast lookup).
  Called by webhook handler when template status changes.
  """
  def mark_template_paused(template_name) do
    key = "template:#{template_name}:status"
    case Redix.command(:redix, ["SET", key, "PAUSED", "EX", 86400]) do  # Expires in 24h
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Check if a template is marked as paused in cache.
  Returns true if paused, false otherwise.
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

  @doc """
  Atomic template switch: Switch to next fallback if current is paused.
  Returns {:ok, new_template} if switched, {:ok, :no_change} if current is fine,
  or {:error, :all_templates_exhausted} if no fallbacks available.
  """
  def switch_to_next_template_if_needed(campaign_id, current_template_name) do
    if is_template_paused?(current_template_name) do
      case get_next_fallback_template(campaign_id, current_template_name) do
        {:ok, next_template} ->
          # Atomically update the active template
          set_active_template(campaign_id, next_template.template_name, next_template.language_code)
          require Logger
          Logger.warning("Template switch: #{current_template_name} -> #{next_template.template_name} (paused)")
          {:ok, next_template}
        
        {:error, :no_fallback_available} ->
          {:error, :all_templates_exhausted}
      end
    else
      {:ok, :no_change}
    end
  end

  defp template_key(campaign_id) do
    "#{@key_prefix}:#{campaign_id}:#{@template_suffix}"
  end
end
