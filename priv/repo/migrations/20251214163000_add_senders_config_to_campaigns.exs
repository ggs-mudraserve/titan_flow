defmodule TitanFlow.Repo.Migrations.AddSendersConfigToCampaigns do
  use Ecto.Migration

  def change do
    alter table(:campaigns) do
      # New senders_config: [{phone_id: 1, template_ids: [101, 102]}, ...]
      add :senders_config, {:array, :map}, default: []
    end
  end
end
