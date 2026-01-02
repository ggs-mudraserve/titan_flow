defmodule TitanFlowWeb.FaqLive.Index do
  use TitanFlowWeb, :live_view

  alias TitanFlow.Faqs

  @impl true
  def mount(_params, _session, socket) do
    Faqs.ensure_default_sets()
    faq_sets = Faqs.list_faq_sets()
    selected_set_id = first_set_id(faq_sets)

    socket =
      socket
      |> assign(current_path: "/faqs")
      |> assign(page_title: "FAQs")
      |> assign(faq_sets: faq_sets)
      |> assign(selected_set_id: selected_set_id)
      |> assign(edit_answer_id: nil)
      |> assign(edit_answer_text: "")
      |> assign(edit_question_id: nil)
      |> assign(edit_question_text: "")
      |> load_answers(selected_set_id)

    {:ok, socket}
  end

  @impl true
  def handle_event("change_set", %{"faq_set_id" => set_id}, socket) do
    selected_set_id = parse_id(set_id)

    socket =
      socket
      |> assign(selected_set_id: selected_set_id)
      |> assign(edit_answer_id: nil, edit_question_id: nil)
      |> load_answers(selected_set_id)

    {:noreply, socket}
  end

  @impl true
  def handle_event("add_answer", %{"answer_text" => answer_text} = params, socket) do
    question_text = Map.get(params, "question_text", "")

    cond do
      is_nil(socket.assigns.selected_set_id) ->
        {:noreply, put_flash(socket, :error, "Select an FAQ set first")}

      String.trim(answer_text) == "" ->
        {:noreply, put_flash(socket, :error, "Answer text is required")}

      true ->
        with {:ok, answer} <-
               Faqs.get_or_create_answer(socket.assigns.selected_set_id, answer_text),
             _ <- maybe_add_question(socket.assigns.selected_set_id, answer.id, question_text) do
          {:noreply, load_answers(socket, socket.assigns.selected_set_id)}
        else
          {:error, changeset} ->
            {:noreply, put_flash(socket, :error, format_errors(changeset))}
        end
    end
  end

  @impl true
  def handle_event(
        "add_question",
        %{"answer_id" => answer_id, "question_text" => question_text},
        socket
      ) do
    answer_id = parse_id(answer_id)

    cond do
      is_nil(answer_id) ->
        {:noreply, socket}

      String.trim(question_text) == "" ->
        {:noreply, put_flash(socket, :error, "Question text is required")}

      true ->
        case Faqs.get_or_create_question(socket.assigns.selected_set_id, answer_id, question_text) do
          {:ok, _} ->
            {:noreply, load_answers(socket, socket.assigns.selected_set_id)}

          {:error, changeset} ->
            {:noreply, put_flash(socket, :error, format_errors(changeset))}
        end
    end
  end

  @impl true
  def handle_event("edit_answer", %{"id" => id}, socket) do
    answer = id |> parse_id() |> Faqs.get_answer!()

    {:noreply,
     assign(socket,
       edit_answer_id: answer.id,
       edit_answer_text: answer.answer_text,
       edit_question_id: nil,
       edit_question_text: ""
     )}
  end

  @impl true
  def handle_event("cancel_edit_answer", _params, socket) do
    {:noreply, assign(socket, edit_answer_id: nil, edit_answer_text: "")}
  end

  @impl true
  def handle_event("save_answer", %{"answer_id" => id, "answer_text" => answer_text}, socket) do
    answer = id |> parse_id() |> Faqs.get_answer!()

    case Faqs.update_answer(answer, %{answer_text: answer_text}) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(edit_answer_id: nil, edit_answer_text: "")
         |> load_answers(socket.assigns.selected_set_id)}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, format_errors(changeset))}
    end
  end

  @impl true
  def handle_event("delete_answer", %{"id" => id}, socket) do
    answer = id |> parse_id() |> Faqs.get_answer!()

    case Faqs.delete_answer(answer) do
      {:ok, _} ->
        {:noreply, load_answers(socket, socket.assigns.selected_set_id)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("edit_question", %{"id" => id}, socket) do
    question = id |> parse_id() |> Faqs.get_question!()

    {:noreply,
     assign(socket,
       edit_question_id: question.id,
       edit_question_text: question.question_text,
       edit_answer_id: nil,
       edit_answer_text: ""
     )}
  end

  @impl true
  def handle_event("cancel_edit_question", _params, socket) do
    {:noreply, assign(socket, edit_question_id: nil, edit_question_text: "")}
  end

  @impl true
  def handle_event(
        "save_question",
        %{"question_id" => id, "question_text" => question_text},
        socket
      ) do
    question = id |> parse_id() |> Faqs.get_question!()

    case Faqs.update_question(question, %{question_text: question_text}) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(edit_question_id: nil, edit_question_text: "")
         |> load_answers(socket.assigns.selected_set_id)}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, format_errors(changeset))}
    end
  end

  @impl true
  def handle_event("delete_question", %{"id" => id}, socket) do
    question = id |> parse_id() |> Faqs.get_question!()

    case Faqs.delete_question(question) do
      {:ok, _} ->
        {:noreply, load_answers(socket, socket.assigns.selected_set_id)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(reason)}")}
    end
  end

  defp load_answers(socket, nil), do: assign(socket, answers: [])

  defp load_answers(socket, faq_set_id) do
    answers = Faqs.list_answers_with_questions(faq_set_id)
    assign(socket, answers: answers)
  end

  defp first_set_id([]), do: nil
  defp first_set_id([set | _]), do: set.id

  defp parse_id(nil), do: nil
  defp parse_id(""), do: nil
  defp parse_id(id) when is_integer(id), do: id

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, _} -> int
      _ -> nil
    end
  end

  defp maybe_add_question(_faq_set_id, _answer_id, question_text) when question_text in [nil, ""],
    do: :ok

  defp maybe_add_question(faq_set_id, answer_id, question_text) do
    Faqs.get_or_create_question(faq_set_id, answer_id, question_text)
  end

  defp format_errors(changeset) do
    changeset.errors
    |> Enum.map(fn {field, {msg, _}} -> "#{field} #{msg}" end)
    |> Enum.join(", ")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_header title="FAQs" />

    <div class="space-y-6">
      <div class="bg-zinc-900 rounded-lg border border-zinc-800 p-5">
        <div class="flex items-center justify-between gap-6">
          <div>
            <h2 class="text-sm font-semibold text-zinc-200">FAQ Set</h2>
            <p class="text-xs text-zinc-500 mt-1">
              Select the FAQ set to manage. Numbers connected to this set will use these answers.
            </p>
          </div>
          <form phx-change="change_set" class="w-64">
            <.select
              name="faq_set_id"
              value={@selected_set_id}
              options={Enum.map(@faq_sets, fn set -> {set.name, set.id} end)}
            />
          </form>
        </div>
      </div>

      <div class="bg-zinc-900 rounded-lg border border-zinc-800 p-5">
        <h2 class="text-sm font-semibold text-zinc-200">Add Answer</h2>
        <p class="text-xs text-zinc-500 mt-1">
          Add one answer and optionally attach a first question.
        </p>

        <form phx-submit="add_answer" class="mt-4 space-y-3">
          <div>
            <label class="block text-xs font-medium text-zinc-400 mb-2">Answer</label>
            <textarea
              name="answer_text"
              rows="3"
              class="w-full rounded-md text-sm bg-zinc-900 border border-zinc-800 text-zinc-100 placeholder-zinc-500 hover:border-zinc-700 focus:outline-none focus:ring-1 focus:ring-indigo-500/50 focus:border-indigo-500 p-3"
              placeholder="Type the answer that should be sent"
            ></textarea>
          </div>

          <div>
            <label class="block text-xs font-medium text-zinc-400 mb-2">First Question (optional)</label>
            <.input
              name="question_text"
              placeholder="Add a matching question"
            />
          </div>

          <div class="flex justify-end">
            <.button type="submit" size={:sm}>Add Answer</.button>
          </div>
        </form>
      </div>

      <div class="space-y-4">
        <%= if Enum.empty?(@answers) do %>
          <div class="bg-zinc-900 rounded-lg border border-zinc-800 p-8 text-center text-sm text-zinc-500">
            No FAQ answers yet. Add one to get started.
          </div>
        <% else %>
          <%= for answer <- @answers do %>
            <div class="bg-zinc-900 rounded-lg border border-zinc-800 p-5 space-y-4">
              <div class="flex items-start justify-between gap-4">
                <div class="flex-1">
                  <p class="text-xs text-zinc-500 mb-2">Answer</p>

                  <%= if @edit_answer_id == answer.id do %>
                    <form phx-submit="save_answer" class="space-y-3">
                      <input type="hidden" name="answer_id" value={answer.id} />
                      <textarea
                        name="answer_text"
                        rows="3"
                        class="w-full rounded-md text-sm bg-zinc-900 border border-zinc-800 text-zinc-100 placeholder-zinc-500 hover:border-zinc-700 focus:outline-none focus:ring-1 focus:ring-indigo-500/50 focus:border-indigo-500 p-3"
                      ><%= @edit_answer_text %></textarea>
                      <div class="flex gap-2">
                        <.button type="submit" size={:xs}>Save</.button>
                        <.button type="button" variant={:ghost} size={:xs} phx-click="cancel_edit_answer">
                          Cancel
                        </.button>
                      </div>
                    </form>
                  <% else %>
                    <p class="text-sm text-zinc-100 whitespace-pre-wrap"><%= answer.answer_text %></p>
                  <% end %>
                </div>
                <%= if @edit_answer_id != answer.id do %>
                  <div class="flex items-center gap-2">
                    <.button type="button" variant={:secondary} size={:xs} phx-click="edit_answer" phx-value-id={answer.id}>
                      Edit
                    </.button>
                    <.button
                      type="button"
                      variant={:danger}
                      size={:xs}
                      phx-click="delete_answer"
                      phx-value-id={answer.id}
                      data-confirm="Delete this answer and all its questions?"
                    >
                      Delete
                    </.button>
                  </div>
                <% end %>
              </div>

              <div>
                <p class="text-xs text-zinc-500 mb-2">Questions</p>
                <div class="space-y-2">
                  <%= for question <- answer.questions do %>
                    <div class="flex items-start justify-between gap-3 bg-zinc-950/60 border border-zinc-800 rounded-md px-3 py-2">
                      <%= if @edit_question_id == question.id do %>
                        <form phx-submit="save_question" class="w-full space-y-2">
                          <input type="hidden" name="question_id" value={question.id} />
                          <.input name="question_text" value={@edit_question_text} />
                          <div class="flex gap-2">
                            <.button type="submit" size={:xs}>Save</.button>
                            <.button type="button" variant={:ghost} size={:xs} phx-click="cancel_edit_question">
                              Cancel
                            </.button>
                          </div>
                        </form>
                      <% else %>
                        <p class="text-sm text-zinc-200 flex-1"><%= question.question_text %></p>
                        <div class="flex items-center gap-2">
                          <.button
                            type="button"
                            variant={:ghost}
                            size={:xs}
                            phx-click="edit_question"
                            phx-value-id={question.id}
                          >
                            Edit
                          </.button>
                          <.button
                            type="button"
                            variant={:ghost}
                            size={:xs}
                            phx-click="delete_question"
                            phx-value-id={question.id}
                            data-confirm="Delete this question?"
                          >
                            Delete
                          </.button>
                        </div>
                      <% end %>
                    </div>
                  <% end %>

                  <form
                    phx-submit="add_question"
                    class="flex items-center gap-2"
                  >
                    <input type="hidden" name="answer_id" value={answer.id} />
                    <.input name="question_text" placeholder="Add another question" />
                    <.button type="submit" size={:xs}>Add</.button>
                  </form>
                </div>
              </div>
            </div>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end
end
