defmodule TitanFlow.Repo.Migrations.CreateContactHistory do
  use Ecto.Migration

  @doc """
  Creates the contact_history table for instant 30-day deduplication.

  This is a lightweight "Master History Table" that tracks the last time
  each phone number was contacted. Much faster than scanning message_logs.
  """
  def change do
    create table(:contact_history, primary_key: false) do
      add :phone_number, :string, primary_key: true, null: false
      add :last_sent_at, :utc_datetime, null: false
      add :last_campaign_id, :integer

      timestamps()
    end

    # Index for time-based queries (e.g., "contacted in last 30 days")
    create index(:contact_history, [:last_sent_at])
  end
end
