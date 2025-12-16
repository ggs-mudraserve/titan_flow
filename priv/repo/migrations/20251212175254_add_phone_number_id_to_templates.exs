defmodule TitanFlow.Repo.Migrations.AddPhoneNumberIdToTemplates do
  use Ecto.Migration

  def change do
    alter table(:templates) do
      add :phone_number_id, references(:phone_numbers, on_delete: :nilify_all)
      add :phone_display_name, :string
    end

    create index(:templates, [:phone_number_id])
  end
end
