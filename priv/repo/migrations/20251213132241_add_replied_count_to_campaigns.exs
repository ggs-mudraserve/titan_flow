defmodule TitanFlow.Repo.Migrations.AddRepliedCountToCampaigns do
  use Ecto.Migration

  def change do
    alter table(:campaigns) do
      add :replied_count, :integer, default: 0
    end
  end
end
