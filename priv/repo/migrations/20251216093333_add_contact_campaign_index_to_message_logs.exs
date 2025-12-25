defmodule TitanFlow.Repo.Migrations.AddContactCampaignIndexToMessageLogs do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @doc """
  Adds critical index for LEFT JOIN in fetch_unsent_contacts.

  Without this index, the BufferManager query:
  LEFT JOIN message_logs m ON m.contact_id = c.id AND m.campaign_id = c.campaign_id

  Performs a full table scan on message_logs (can take 5-10 seconds at 180K messages).

  With this index: 0.1-0.5 seconds per batch.

  Using CONCURRENTLY to allow index creation without locking the table during production.
  """
  def change do
    create_if_not_exists index(:message_logs, [:contact_id, :campaign_id], concurrently: true)
  end
end
