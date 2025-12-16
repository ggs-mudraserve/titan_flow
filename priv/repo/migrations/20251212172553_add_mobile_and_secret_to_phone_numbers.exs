defmodule TitanFlow.Repo.Migrations.AddMobileAndSecretToPhoneNumbers do
  use Ecto.Migration

  def change do
    alter table(:phone_numbers) do
      add :mobile_number, :string
      add :app_secret, :string
    end
  end
end
