defmodule TitanFlow.Repo.Migrations.AddCampaignTrackingFields do
  use Ecto.Migration

  def change do
    alter table(:campaigns) do
      add :sent_count, :integer, default: 0
      add :delivered_count, :integer, default: 0
      add :read_count, :integer, default: 0
      add :failed_count, :integer, default: 0
    end
  end
end
