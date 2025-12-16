defmodule TitanFlow.Repo.Migrations.AddCoreTables do
  use Ecto.Migration

  def change do
    # Phone Numbers table
    create table(:phone_numbers) do
      add :waba_id, :text
      add :phone_number_id, :text
      add :display_name, :text
      add :quality_rating, :text, default: "GREEN"
      add :daily_limit, :text
      add :is_warmup_active, :boolean, default: false
      add :warmup_started_at, :utc_datetime

      timestamps()
    end

    # Templates table
    create table(:templates) do
      add :meta_template_id, :text
      add :name, :text
      add :status, :text
      add :components, :map
      add :health_score, :text

      timestamps()
    end

    # Media Assets table (for sending)
    create table(:media_assets) do
      add :meta_media_id, :text
      add :file_name, :text
      add :file_size_bytes, :bigint
      add :expires_at, :utc_datetime

      timestamps()
    end

    # Campaigns table
    create table(:campaigns) do
      add :name, :text
      add :status, :text
      add :total_records, :integer
      add :primary_template_id, references(:templates, on_delete: :nothing)
      add :fallback_template_id, references(:templates, on_delete: :nothing)

      timestamps()
    end

    create index(:campaigns, [:primary_template_id])
    create index(:campaigns, [:fallback_template_id])

    # Contacts table
    create table(:contacts) do
      add :phone, :text
      add :name, :text
      add :variables, :map
      add :campaign_id, references(:campaigns, on_delete: :delete_all)
      add :is_blacklisted, :boolean, default: false

      timestamps()
    end

    create index(:contacts, [:campaign_id])
    create index(:contacts, [:phone])
  end
end
