defmodule TitanFlow.Repo.Migrations.RefactorApiKeyStorage do
  use Ecto.Migration

  def change do
    create table(:global_configs, primary_key: false) do
      add :key, :string, primary_key: true
      add :value, :text
      timestamps()
    end

    alter table(:phone_numbers) do
      remove :openai_api_key
    end
  end
end
