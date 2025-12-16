defmodule TitanFlow.Repo.Migrations.AddSystemPromptToPhoneNumbers do
  use Ecto.Migration

  def change do
    alter table(:phone_numbers) do
      add :system_prompt, :text, default: "You are a helpful assistant. Keep answers short."
    end
  end
end
