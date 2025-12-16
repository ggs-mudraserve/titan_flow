defmodule TitanFlow.Repo.Migrations.AddColumnsToTemplates do
  use Ecto.Migration

  def change do
    alter table(:templates) do
      add :language, :text
      add :category, :text
    end
  end
end
