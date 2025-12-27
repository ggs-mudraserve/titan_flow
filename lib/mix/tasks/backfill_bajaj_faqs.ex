defmodule Mix.Tasks.TitanFlow.BackfillBajajFaqs do
  @moduledoc """
  Build the initial Bajaj FAQ set from existing AI replies.

  ## Usage

      mix titan_flow.backfill_bajaj_faqs

  ## What it does

  1. Finds the most common AI answers.
  2. Picks the top 5 answers.
  3. Attaches up to 5 inbound questions per answer.

  This task is safe to run multiple times.
  """
  use Mix.Task

  require Logger

  alias TitanFlow.Faqs
  alias TitanFlow.Faqs.Normalizer
  alias TitanFlow.Repo

  @shortdoc "Backfill Bajaj FAQ from existing AI replies"

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    Logger.info("Ensuring default FAQ sets...")
    Faqs.ensure_default_sets()

    case Faqs.get_faq_set_by_slug("bajaj") do
      nil ->
        Mix.raise("Bajaj FAQ set not found")

      faq_set ->
        Logger.info("Building FAQ answers for #{faq_set.name}...")
        backfill_for_set(faq_set.id)
    end
  end

  defp backfill_for_set(faq_set_id) do
    top_answers =
      fetch_top_answers()
      |> Enum.reduce(%{}, &merge_answer/2)
      |> Map.values()
      |> Enum.sort_by(& &1.count, :desc)
      |> Enum.take(5)

    Logger.info("Selected #{length(top_answers)} answers for backfill")

    Enum.each(top_answers, fn %{text: answer_text} ->
      with {:ok, answer} <- Faqs.get_or_create_answer(faq_set_id, answer_text) do
        questions = fetch_top_questions(answer_text)

        _ =
          Enum.reduce_while(questions, {MapSet.new(), 0}, fn question_text, {seen, count} ->
            normalized = Normalizer.normalize(question_text)

            cond do
              count >= 5 ->
                {:halt, {seen, count}}

              normalized == "" ->
                {:cont, {seen, count}}

              Normalizer.short_message?(normalized) ->
                {:cont, {seen, count}}

              MapSet.member?(seen, normalized) ->
                {:cont, {seen, count}}

              true ->
                _ = Faqs.get_or_create_question(faq_set_id, answer.id, question_text)
                {:cont, {MapSet.put(seen, normalized), count + 1}}
            end
          end)
      end
    end)
  end

  defp fetch_top_answers do
    sql = """
    SELECT content, COUNT(*) AS cnt
    FROM messages
    WHERE direction = 'outbound'
      AND is_ai_generated = true
      AND content IS NOT NULL
      AND content <> ''
    GROUP BY content
    ORDER BY cnt DESC
    LIMIT 200
    """

    case Repo.query(sql) do
      {:ok, result} -> result.rows
      {:error, error} -> Mix.raise("Failed to fetch answers: #{inspect(error)}")
    end
  end

  defp merge_answer([content, count], acc) do
    normalized = Normalizer.normalize(content)

    if normalized == "" do
      acc
    else
      Map.update(acc, normalized, %{text: content, count: count}, fn current ->
        if count > current.count do
          %{text: content, count: count}
        else
          %{current | count: current.count + count}
        end
      end)
    end
  end

  defp fetch_top_questions(answer_text) do
    sql = """
    SELECT q.content, COUNT(*) AS cnt
    FROM messages AS a
    JOIN LATERAL (
      SELECT m.content
      FROM messages AS m
      WHERE m.conversation_id = a.conversation_id
        AND m.direction = 'inbound'
        AND m.inserted_at <= a.inserted_at
      ORDER BY m.inserted_at DESC
      LIMIT 1
    ) AS q ON true
    WHERE a.direction = 'outbound'
      AND a.is_ai_generated = true
      AND a.content = $1
      AND q.content IS NOT NULL
      AND q.content <> ''
    GROUP BY q.content
    ORDER BY cnt DESC
    LIMIT 50
    """

    case Repo.query(sql, [answer_text]) do
      {:ok, result} ->
        Enum.map(result.rows, fn [content, _count] -> content end)

      {:error, error} ->
        Logger.warning("Failed to fetch questions: #{inspect(error)}")
        []
    end
  end
end
