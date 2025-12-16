defmodule TitanFlow.Repo.Migrations.AddCampaignInsightsFields do
  use Ecto.Migration

  def change do
    alter table(:campaigns) do
      add :started_at, :naive_datetime
      add :completed_at, :naive_datetime
    end

    alter table(:message_logs) do
      add :template_name, :text
    end
  end
end
