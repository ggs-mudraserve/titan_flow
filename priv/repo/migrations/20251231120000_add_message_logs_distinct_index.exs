defmodule TitanFlow.Repo.Migrations.AddMessageLogsDistinctIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @doc """
  Speeds up DISTINCT ON recipient_phone queries for realtime stats.
  Uses a composite index with campaign filter and ordering by latest sent_at.
  """
  def change do
    create_if_not_exists index(:message_logs, [:campaign_id, :recipient_phone, :sent_at],
                           name: :idx_message_logs_campaign_recipient_sent_at,
                           concurrently: true
                         )
  end
end
