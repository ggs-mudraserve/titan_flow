defmodule TitanFlow.Faqs do
  @moduledoc """
  Context for FAQ matching and management.
  """
  import Ecto.Query

  alias TitanFlow.Repo
  alias TitanFlow.Settings
  alias TitanFlow.Faqs.{FaqAnswer, FaqQuestion, FaqSet, Normalizer}

  @similarity_threshold 0.75

  def faq_enabled? do
    Settings.get_value("faq_enabled", "true")
    |> to_bool(true)
  end

  def list_faq_sets do
    Repo.all(from s in FaqSet, order_by: [asc: s.name])
  end

  def get_faq_set!(id), do: Repo.get!(FaqSet, id)

  def get_faq_set_by_slug(slug) when is_binary(slug) do
    Repo.get_by(FaqSet, slug: slug)
  end

  def list_answers_with_questions(faq_set_id) do
    questions_query = from q in FaqQuestion, order_by: [asc: q.inserted_at]

    FaqAnswer
    |> where([a], a.faq_set_id == ^faq_set_id)
    |> order_by([a], asc: a.inserted_at)
    |> preload(questions: ^questions_query)
    |> Repo.all()
  end

  def get_answer!(id), do: Repo.get!(FaqAnswer, id)

  def get_question!(id), do: Repo.get!(FaqQuestion, id)

  def create_faq_set(attrs \\ %{}) do
    %FaqSet{}
    |> FaqSet.changeset(attrs)
    |> Repo.insert()
  end

  def create_answer(attrs \\ %{}) do
    %FaqAnswer{}
    |> FaqAnswer.changeset(attrs)
    |> Repo.insert()
  end

  def update_answer(%FaqAnswer{} = answer, attrs) do
    answer
    |> FaqAnswer.changeset(attrs)
    |> Repo.update()
  end

  def create_question(attrs \\ %{}) do
    %FaqQuestion{}
    |> FaqQuestion.changeset(attrs)
    |> Repo.insert()
  end

  def update_question(%FaqQuestion{} = question, attrs) do
    question
    |> FaqQuestion.changeset(attrs)
    |> Repo.update()
  end

  def delete_answer(%FaqAnswer{} = answer) do
    Repo.delete(answer)
  end

  def delete_question(%FaqQuestion{} = question) do
    Repo.delete(question)
  end

  def get_or_create_answer(faq_set_id, answer_text) do
    normalized = Normalizer.normalize(answer_text)

    case Repo.get_by(FaqAnswer, faq_set_id: faq_set_id, normalized_answer: normalized) do
      nil ->
        create_answer(%{
          faq_set_id: faq_set_id,
          answer_text: answer_text
        })

      answer ->
        {:ok, answer}
    end
  end

  def get_or_create_question(faq_set_id, faq_answer_id, question_text) do
    normalized = Normalizer.normalize(question_text)

    case Repo.get_by(FaqQuestion, faq_set_id: faq_set_id, normalized_question: normalized) do
      nil ->
        create_question(%{
          faq_set_id: faq_set_id,
          faq_answer_id: faq_answer_id,
          question_text: question_text
        })

      question ->
        {:ok, question}
    end
  end

  def match_question(nil, _question_text), do: :no_match

  def match_question(faq_set_id, question_text) do
    if faq_enabled?() do
      normalized = Normalizer.normalize(question_text)

      cond do
        normalized == "" ->
          :no_match

        Normalizer.short_message?(normalized) ->
          match_exact(faq_set_id, normalized)

        true ->
          case match_exact(faq_set_id, normalized) do
            {:ok, answer} -> {:ok, answer}
            :no_match -> match_fuzzy(faq_set_id, normalized)
          end
      end
    else
      :no_match
    end
  rescue
    _ -> {:error, :match_failed}
  end

  def ensure_default_sets do
    [
      %{name: "Bajaj", slug: "bajaj"},
      %{name: "Tata", slug: "tata"},
      %{name: "Incred", slug: "incred"}
    ]
    |> Enum.each(fn attrs ->
      Repo.insert(FaqSet.changeset(%FaqSet{}, attrs),
        on_conflict: :nothing,
        conflict_target: :slug
      )
    end)

    :ok
  end

  defp match_exact(faq_set_id, normalized) do
    query =
      from q in FaqQuestion,
        join: a in assoc(q, :answer),
        where:
          q.faq_set_id == ^faq_set_id and q.active == true and a.active == true and
            q.normalized_question == ^normalized,
        limit: 1,
        select: a

    case Repo.one(query) do
      nil -> :no_match
      answer -> {:ok, answer}
    end
  end

  defp match_fuzzy(faq_set_id, normalized) do
    query =
      from q in FaqQuestion,
        join: a in assoc(q, :answer),
        where: q.faq_set_id == ^faq_set_id and q.active == true and a.active == true,
        where: fragment("similarity(?, ?) > ?", q.normalized_question, ^normalized, ^@similarity_threshold),
        order_by: [desc: fragment("similarity(?, ?)", q.normalized_question, ^normalized)],
        limit: 1,
        select: a

    case Repo.one(query) do
      nil -> :no_match
      answer -> {:ok, answer}
    end
  end

  defp to_bool(nil, default), do: default

  defp to_bool(value, _default) when is_boolean(value), do: value

  defp to_bool(value, _default) do
    normalized =
      value
      |> to_string()
      |> String.downcase()
      |> String.trim()

    normalized in ["true", "1", "yes", "on"]
  end
end
