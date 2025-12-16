defmodule TitanFlow.Repo.Migrations.AddPhoneAndTemplateIdsToCampaigns do
  use Ecto.Migration

  def change do
    alter table(:campaigns) do
      add :phone_ids, {:array, :integer}, default: []
      add :template_ids, {:array, :integer}, default: []
    end
  end
end
