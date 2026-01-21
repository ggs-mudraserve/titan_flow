defmodule TitanFlow.Repo.Migrations.CreateCampaignContactStatus do
  use Ecto.Migration

  def change do
    create table(:campaign_contact_status) do
      add :campaign_id, references(:campaigns, on_delete: :delete_all), null: false
      add :contact_id, references(:contacts, on_delete: :delete_all), null: false
      add :last_status, :text, null: false
      add :last_error_code, :text

      timestamps()
    end

    create unique_index(:campaign_contact_status, [:campaign_id, :contact_id])
    create index(:campaign_contact_status, [:campaign_id, :last_status])
    create index(:campaign_contact_status, [:campaign_id, :last_status, :last_error_code])
  end
end
