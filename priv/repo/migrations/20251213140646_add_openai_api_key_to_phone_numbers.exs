defmodule TitanFlow.Repo.Migrations.AddOpenaiApiKeyToPhoneNumbers do
  use Ecto.Migration

  def change do
    alter table(:phone_numbers) do
      add :openai_api_key, :text
    end
  end
end
