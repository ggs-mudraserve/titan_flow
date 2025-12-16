defmodule TitanFlow.Repo.Migrations.AddInboxTables do
  use Ecto.Migration

  def change do
    create table(:conversations) do
      add :contact_phone, :text, null: false
      add :contact_name, :text
      add :phone_number_id, references(:phone_numbers, on_delete: :nilify_all)
      add :last_message_at, :utc_datetime
      add :last_message_preview, :text
      add :unread_count, :integer, default: 0
      add :is_ai_paused, :boolean, default: false
      add :status, :text, default: "open"

      timestamps()
    end

    create index(:conversations, [:contact_phone])
    create index(:conversations, [:phone_number_id])
    create index(:conversations, [:last_message_at])
    create unique_index(:conversations, [:contact_phone, :phone_number_id])

    create table(:messages) do
      add :conversation_id, references(:conversations, on_delete: :delete_all), null: false
      add :direction, :text, null: false  # "inbound" or "outbound"
      add :content, :text
      add :message_type, :text, default: "text"  # text, image, video, template
      add :meta_message_id, :text
      add :status, :text  # sent, delivered, read, failed
      add :template_name, :text
      add :is_ai_generated, :boolean, default: false

      timestamps()
    end

    create index(:messages, [:conversation_id])
    create index(:messages, [:inserted_at])
  end
end
