defmodule TitanFlow.Campaigns do
  @moduledoc """
  Context module for campaign management.
  """

  import Ecto.Query
  alias TitanFlow.Repo
  alias TitanFlow.Campaigns.Campaign

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
  defp maybe_preload(campaign), do: Repo.preload(campaign, [:primary_template, :fallback_template])

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
    
    entries = Campaign
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
  Returns an `%Ecto.Changeset{}` for tracking campaign changes.
  """
  def change_campaign(%Campaign{} = campaign, attrs \\ %{}) do
    Campaign.changeset(campaign, attrs)
  end
end
