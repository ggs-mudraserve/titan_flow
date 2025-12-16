defmodule TitanFlow.Repo.Migrations.AddAccessTokenToPhoneNumbers do
  use Ecto.Migration

  def change do
    alter table(:phone_numbers) do
      add :access_token, :text
    end
  end
end
