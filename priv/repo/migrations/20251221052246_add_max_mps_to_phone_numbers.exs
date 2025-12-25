defmodule TitanFlow.Repo.Migrations.AddMaxMpsToPhoneNumbers do
  use Ecto.Migration

  def change do
    alter table(:phone_numbers) do
      add :max_mps, :integer, default: 80, null: false
    end

    # Create check constraint for valid MPS range (10-500)
    create constraint(:phone_numbers, :max_mps_range, check: "max_mps >= 10 AND max_mps <= 500")
  end
end
