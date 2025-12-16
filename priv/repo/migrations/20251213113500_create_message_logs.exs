defmodule TitanFlow.Repo.Migrations.CreateMessageLogs do
  use Ecto.Migration

  def change do
    create table(:message_logs) do
      add :meta_message_id, :text, null: false
      add :campaign_id, references(:campaigns, on_delete: :delete_all)
      add :contact_id, references(:contacts, on_delete: :delete_all)
      add :phone_number_id, :text
      add :recipient_phone, :text
      add :status, :text, default: "sent"  # sent, delivered, read, failed
      add :error_code, :text
      add :error_message, :text
      add :sent_at, :utc_datetime
      add :delivered_at, :utc_datetime
      add :read_at, :utc_datetime

      timestamps()
    end

    create unique_index(:message_logs, [:meta_message_id])
    create index(:message_logs, [:campaign_id])
    create index(:message_logs, [:contact_id])
    create index(:message_logs, [:status])
  end
end
