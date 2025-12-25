defmodule TitanFlow.Repo.Migrations.AddHasRepliedToMessageLogs do
  use Ecto.Migration

  def change do
    alter table(:message_logs) do
      add :has_replied, :boolean, default: false
    end

    create index(:message_logs, [:has_replied])
  end
end
