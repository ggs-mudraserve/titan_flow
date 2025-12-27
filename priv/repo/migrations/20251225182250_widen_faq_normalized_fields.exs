defmodule TitanFlow.Repo.Migrations.WidenFaqNormalizedFields do
  use Ecto.Migration

  def change do
    alter table(:faq_answers) do
      modify :normalized_answer, :text, null: false
    end

    alter table(:faq_questions) do
      modify :normalized_question, :text, null: false
    end
  end
end
