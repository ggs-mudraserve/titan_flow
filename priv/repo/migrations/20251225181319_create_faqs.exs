defmodule TitanFlow.Repo.Migrations.CreateFaqs do
  use Ecto.Migration

  def change do
    execute("CREATE EXTENSION IF NOT EXISTS pg_trgm")

    create table(:faq_sets) do
      add :name, :string, null: false
      add :slug, :string, null: false
      add :active, :boolean, default: true, null: false

      timestamps()
    end

    create unique_index(:faq_sets, [:slug])

    create table(:faq_answers) do
      add :faq_set_id, references(:faq_sets, on_delete: :delete_all), null: false
      add :answer_text, :text, null: false
      add :normalized_answer, :string, null: false
      add :active, :boolean, default: true, null: false

      timestamps()
    end

    create index(:faq_answers, [:faq_set_id])
    create unique_index(:faq_answers, [:faq_set_id, :normalized_answer])

    create table(:faq_questions) do
      add :faq_set_id, references(:faq_sets, on_delete: :delete_all), null: false
      add :faq_answer_id, references(:faq_answers, on_delete: :delete_all), null: false
      add :question_text, :text, null: false
      add :normalized_question, :string, null: false
      add :active, :boolean, default: true, null: false

      timestamps()
    end

    create index(:faq_questions, [:faq_set_id])
    create index(:faq_questions, [:faq_answer_id])
    create unique_index(:faq_questions, [:faq_set_id, :normalized_question])

    execute(
      "CREATE INDEX IF NOT EXISTS faq_questions_normalized_question_trgm_idx ON faq_questions USING gin (normalized_question gin_trgm_ops)",
      "DROP INDEX IF EXISTS faq_questions_normalized_question_trgm_idx"
    )

    alter table(:phone_numbers) do
      add :faq_set_id, references(:faq_sets, on_delete: :nilify_all)
    end

    create index(:phone_numbers, [:faq_set_id])

    execute("""
    INSERT INTO faq_sets (name, slug, active, inserted_at, updated_at)
    VALUES
      ('Bajaj', 'bajaj', TRUE, NOW(), NOW()),
      ('Tata', 'tata', TRUE, NOW(), NOW()),
      ('Incred', 'incred', TRUE, NOW(), NOW())
    ON CONFLICT (slug) DO NOTHING
    """)
  end
end
