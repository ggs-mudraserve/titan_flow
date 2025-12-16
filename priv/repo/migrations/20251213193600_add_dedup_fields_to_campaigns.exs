defmodule TitanFlow.Repo.Migrations.AddDedupFieldsToCampaigns do
  use Ecto.Migration

  def change do
    alter table(:campaigns) do
      add :dedup_window_days, :integer, default: 0
      add :skipped_count, :integer, default: 0
    end

    # Create composite index for fast deduplication queries
    create index(:message_logs, [:inserted_at, :recipient_phone], 
      name: :idx_message_logs_dedup
    )
  end
end
