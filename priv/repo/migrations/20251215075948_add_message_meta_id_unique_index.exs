defmodule TitanFlow.Repo.Migrations.AddMessageMetaIdUniqueIndex do
  use Ecto.Migration

  def change do
    # Unique index on meta_message_id for deduplication
    # WHERE clause allows multiple NULL values (messages without meta_id yet)
    create unique_index(:messages, [:meta_message_id],
             where: "meta_message_id IS NOT NULL",
             name: :messages_meta_message_id_unique_index
           )
  end
end
