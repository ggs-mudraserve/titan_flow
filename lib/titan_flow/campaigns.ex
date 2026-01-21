defmodule TitanFlow.Campaigns do
  @moduledoc """
  Context module for campaign management.
  """

  import Ecto.Query
  alias TitanFlow.Repo
  alias TitanFlow.Campaigns.Campaign
  alias TitanFlow.WhatsApp

  @doc """
  Creates a new campaign.
  """
  def create_campaign(attrs \\ %{}) do
    %Campaign{}
    |> Campaign.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Gets a campaign by ID. Raises if not found.
  """
  def get_campaign!(id) do
    Repo.get!(Campaign, id)
    |> Repo.preload([:primary_template, :fallback_template])
  end

  @doc """
  Gets a campaign by ID. Returns nil if not found.
  """
  def get_campaign(id) do
    Repo.get(Campaign, id)
    |> maybe_preload()
  end

  defp maybe_preload(nil), do: nil

  defp maybe_preload(campaign),
    do: Repo.preload(campaign, [:primary_template, :fallback_template])

  @doc """
  Lists campaigns with optional pagination.

  ## Options
  - `page` - Page number (default: 1)
  - `per_page` - Items per page (default: 25, use :all for no pagination)

  ## Returns
  When paginated: %{entries: [...], page: int, total_pages: int, total: int}
  When not paginated (per_page: :all): list of campaigns
  """
  def list_campaigns(page \\ 1, per_page \\ :all)

  # Backward compatible: no pagination (default)
  def list_campaigns(_page, :all) do
    Campaign
    |> order_by(desc: :inserted_at)
    |> Repo.all()
    |> Repo.preload([:primary_template, :fallback_template])
  end

  # Paginated version
  def list_campaigns(page, per_page) when is_integer(per_page) do
    offset = (page - 1) * per_page

    total = Repo.aggregate(Campaign, :count)
    total_pages = max(1, ceil(total / per_page))

    entries =
      Campaign
      |> order_by(desc: :inserted_at)
      |> limit(^per_page)
      |> offset(^offset)
      |> Repo.all()
      |> Repo.preload([:primary_template, :fallback_template])

    %{
      entries: entries,
      page: page,
      total_pages: total_pages,
      total: total
    }
  end

  @doc """
  Lists campaigns with a specific status.
  Used by CompletionChecker to find running campaigns.
  """
  def list_campaigns_by_status(status) when is_binary(status) do
    Campaign
    |> where([c], c.status == ^status)
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  @doc """
  Updates a campaign.
  """
  def update_campaign(%Campaign{} = campaign, attrs) do
    campaign
    |> Campaign.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a campaign.
  """
  def delete_campaign(%Campaign{} = campaign) do
    Repo.delete(campaign)
  end

  @doc """
  Returns the current webhook updates queue depth.
  """
  def webhook_queue_depth do
    try do
      case Redix.command(:redix, ["LLEN", "buffer:webhook_updates"]) do
        {:ok, len} when is_integer(len) -> len
        _ -> 0
      end
    rescue
      _ -> 0
    catch
      :exit, _ -> 0
    end
  end

  @doc """
  Returns true if any campaign is currently running.
  """
  def running_campaigns? do
    try do
      count =
        from(c in Campaign, where: c.status == "running")
        |> Repo.aggregate(:count)

      count > 0
    rescue
      _ -> false
    catch
      :exit, _ -> false
    end
  end

  @doc """
  Returns per-phone pause/exhausted status for a campaign.
  """
  def phone_statuses(campaign_id) do
    try do
      campaign = get_campaign!(campaign_id)

      phone_ids =
        case campaign.senders_config do
          nil -> campaign.phone_ids || []
          config when is_list(config) -> Enum.map(config, fn c -> c["phone_id"] end)
          _ -> campaign.phone_ids || []
        end

      Enum.reduce(phone_ids, [], fn phone_id, acc ->
        phone =
          try do
            WhatsApp.get_phone_number!(phone_id)
          rescue
            _ -> nil
          end

        if phone do
          pause_key =
            "campaign:#{campaign_id}:phone:#{phone.phone_number_id}:131048_pause_until"

          paused_until =
            case Redix.command(:redix, ["GET", pause_key]) do
              {:ok, nil} -> nil
              {:ok, val} -> String.to_integer(val)
              _ -> nil
            end

          paused_until =
            if paused_until && paused_until > System.system_time(:millisecond),
              do: paused_until,
              else: nil

          exhausted =
            case Redix.command(:redix, [
                   "SISMEMBER",
                   "campaign:#{campaign_id}:exhausted_phones",
                   phone.phone_number_id
                 ]) do
              {:ok, 1} -> true
              _ -> false
            end

          pipeline_running =
            try do
              Registry.lookup(TitanFlow.Campaigns.PipelineRegistry, phone.phone_number_id) != []
            catch
              :exit, _ -> false
            end

          preflight_error =
            case Redix.command(:redix, [
                   "GET",
                   "campaign:#{campaign_id}:phone:#{phone.phone_number_id}:preflight_error"
                 ]) do
              {:ok, val} when is_binary(val) and val != "" -> val
              _ -> nil
            end

          last_critical_error =
            case Redix.command(:redix, [
                   "GET",
                   "campaign:#{campaign_id}:phone:#{phone.phone_number_id}:last_critical_error"
                 ]) do
              {:ok, val} when is_binary(val) and val != "" -> val
              _ -> nil
            end

          pipeline_pause_reason =
            cond do
              pipeline_running ->
                nil

              preflight_error ->
                "Pre-flight failed: #{preflight_error}"

              exhausted and last_critical_error ->
                "Exhausted: #{format_error_reason(last_critical_error)}"

              exhausted ->
                "Exhausted: unknown reason"

              paused_until ->
                "Rate limit pause (131048)"

              true ->
                "Pipeline not running"
            end

          [
            %{
              phone_id: phone.id,
              phone_number_id: phone.phone_number_id,
              display_name: phone.display_name,
              paused_until_ms: paused_until,
              exhausted: exhausted,
              pipeline_running: pipeline_running,
              pipeline_pause_reason: pipeline_pause_reason
            }
            | acc
          ]
        else
          acc
        end
      end)
      |> Enum.reverse()
    rescue
      _ -> []
    catch
      :exit, _ -> []
    end
  end

  defp format_error_reason(code) do
    case to_string(code) do
      "131042" -> "payment/eligibility issue (131042)"
      "131048" -> "spam rate limit (131048)"
      "131053" -> "account error (131053)"
      other -> "error #{other}"
    end
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking campaign changes.
  """
  def change_campaign(%Campaign{} = campaign, attrs \\ %{}) do
    Campaign.changeset(campaign, attrs)
  end
end
