defmodule TitanFlow.Faqs.FaqQuestion do
  @moduledoc """
  FAQ question mapped to a single answer.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias TitanFlow.Faqs.{FaqAnswer, FaqSet, Normalizer}

  schema "faq_questions" do
    field :question_text, :string
    field :normalized_question, :string
    field :active, :boolean, default: true

    belongs_to :faq_set, FaqSet
    belongs_to :answer, FaqAnswer, foreign_key: :faq_answer_id

    timestamps()
  end

  def changeset(question, attrs) do
    question
    |> cast(attrs, [:faq_set_id, :faq_answer_id, :question_text, :normalized_question, :active])
    |> validate_required([:faq_set_id, :faq_answer_id, :question_text])
    |> maybe_normalize_question()
    |> unique_constraint(:normalized_question,
      name: :faq_questions_faq_set_id_normalized_question_index
    )
  end

  defp maybe_normalize_question(changeset) do
    case get_change(changeset, :question_text) do
      nil ->
        changeset

      question_text ->
        put_change(changeset, :normalized_question, Normalizer.normalize(question_text))
    end
  end
end
