defmodule TitanFlow.Faqs.FaqAnswer do
  @moduledoc """
  FAQ answer shared by multiple questions.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias TitanFlow.Faqs.{FaqQuestion, FaqSet, Normalizer}

  schema "faq_answers" do
    field :answer_text, :string
    field :normalized_answer, :string
    field :active, :boolean, default: true

    belongs_to :faq_set, FaqSet
    has_many :questions, FaqQuestion

    timestamps()
  end

  def changeset(answer, attrs) do
    answer
    |> cast(attrs, [:faq_set_id, :answer_text, :normalized_answer, :active])
    |> validate_required([:faq_set_id, :answer_text])
    |> maybe_normalize_answer()
    |> unique_constraint(:normalized_answer,
      name: :faq_answers_faq_set_id_normalized_answer_index
    )
  end

  defp maybe_normalize_answer(changeset) do
    case get_change(changeset, :answer_text) do
      nil ->
        changeset

      answer_text ->
        put_change(changeset, :normalized_answer, Normalizer.normalize(answer_text))
    end
  end
end
