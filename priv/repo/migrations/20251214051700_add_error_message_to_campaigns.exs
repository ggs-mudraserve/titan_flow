defmodule TitanFlow.Repo.Migrations.AddErrorMessageToCampaigns do
  use Ecto.Migration

  def change do
    alter table(:campaigns) do
      add :error_message, :text
    end
  end
end
