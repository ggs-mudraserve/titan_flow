defmodule TitanFlow.Repo.Migrations.AddAppIdToPhoneNumbers do
  use Ecto.Migration

  def change do
    alter table(:phone_numbers) do
      add :app_id, :string
    end
  end
end
