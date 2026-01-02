defmodule TitanFlow.Repo.Migrations.CreateContactAssignments do
  use Ecto.Migration

  def change do
    create table(:contact_assignments) do
      add :campaign_id, references(:campaigns, on_delete: :delete_all), null: false
      add :contact_id, references(:contacts, on_delete: :delete_all), null: false
      add :phone_number_id, :text, null: false

      timestamps()
    end

    create index(:contact_assignments, [:campaign_id])
    create index(:contact_assignments, [:campaign_id, :phone_number_id])
    create unique_index(:contact_assignments, [:campaign_id, :contact_id])
  end
end
