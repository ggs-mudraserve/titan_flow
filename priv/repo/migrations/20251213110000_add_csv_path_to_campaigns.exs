defmodule TitanFlow.Repo.Migrations.AddCsvPathToCampaigns do
  use Ecto.Migration

  def change do
    alter table(:campaigns) do
      add :csv_path, :text
    end
  end
end
