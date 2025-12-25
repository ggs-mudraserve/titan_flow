defmodule TitanFlow.Templates do
  @moduledoc """
  Context for template management including sync with Meta API.
  """

  import Ecto.Query
  alias TitanFlow.Repo
  alias TitanFlow.Templates.Template
  alias TitanFlow.WhatsApp

  require Logger

  # Template CRUD

  @doc """
  List templates with optional pagination and filters.

  ## Options
  - `page` - Page number (default: 1)
  - `per_page` - Items per page (default: :all for backward compatibility)
  - `filters` - Map with optional keys: :category, :status, :search, :phone

  ## Returns
  When paginated: %{entries: [...], page: int, total_pages: int, total: int}
  When not paginated (per_page: :all): list of templates
  """
  def list_templates(page \\ 1, per_page \\ :all, filters \\ %{})

  # Backward compatible: no pagination
  def list_templates(_page, :all, filters) do
    base_query()
    |> apply_filters(filters)
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  # Paginated version
  def list_templates(page, per_page, filters) when is_integer(per_page) do
    query =
      base_query()
      |> apply_filters(filters)
      |> order_by(desc: :inserted_at)

    total = Repo.aggregate(query, :count)
    total_pages = max(1, ceil(total / per_page))
    offset = (page - 1) * per_page

    entries =
      query
      |> limit(^per_page)
      |> offset(^offset)
      |> Repo.all()

    %{
      entries: entries,
      page: page,
      total_pages: total_pages,
      total: total
    }
  end

  defp base_query do
    from(t in Template)
  end

  defp apply_filters(query, filters) when is_map(filters) do
    query
    |> filter_by_category(filters[:category])
    |> filter_by_status(filters[:status])
    |> filter_by_search(filters[:search])
    |> filter_by_phone(filters[:phone])
  end

  defp filter_by_category(query, nil), do: query
  defp filter_by_category(query, "all"), do: query

  defp filter_by_category(query, category) do
    cat_upper = String.upcase(category)
    where(query, [t], fragment("UPPER(?)", t.category) == ^cat_upper)
  end

  defp filter_by_status(query, nil), do: query
  defp filter_by_status(query, "all"), do: query

  defp filter_by_status(query, status) do
    status_upper = String.upcase(status)
    where(query, [t], fragment("UPPER(?)", t.status) == ^status_upper)
  end

  defp filter_by_search(query, nil), do: query
  defp filter_by_search(query, ""), do: query

  defp filter_by_search(query, search) do
    pattern = "%#{String.downcase(search)}%"
    where(query, [t], ilike(t.name, ^pattern))
  end

  defp filter_by_phone(query, nil), do: query
  defp filter_by_phone(query, "all"), do: query

  defp filter_by_phone(query, phone_name) do
    where(query, [t], t.phone_display_name == ^phone_name)
  end

  @doc """
  Count templates efficiently (single COUNT query, no data loaded).
  """
  def count_templates do
    Repo.aggregate(Template, :count)
  end

  def get_template!(id), do: Repo.get!(Template, id)

  def get_by_meta_id(meta_template_id) do
    Repo.get_by(Template, meta_template_id: meta_template_id)
  end

  def get_template_by_name(template_name) do
    Repo.get_by(Template, name: template_name)
  end

  def create_template(attrs \\ %{}) do
    %Template{}
    |> Template.changeset(attrs)
    |> Repo.insert()
  end

  def update_template(%Template{} = template, attrs) do
    template
    |> Template.changeset(attrs)
    |> Repo.update()
  end

  def delete_template(%Template{} = template) do
    Repo.delete(template)
  end

  def change_template(%Template{} = template, attrs \\ %{}) do
    Template.changeset(template, attrs)
  end

  @doc """
  Sync templates from Meta API for all configured phone numbers.
  Returns {:ok, count} or {:error, reason}.
  """
  def sync_from_meta do
    phone_numbers = WhatsApp.list_phone_numbers()

    if Enum.empty?(phone_numbers) do
      {:error, :no_phone_numbers}
    else
      total =
        phone_numbers
        |> Enum.map(&sync_templates_for_waba/1)
        |> Enum.sum()

      {:ok, total}
    end
  end

  def sync_templates_for_waba(phone_number) do
    url = "https://graph.facebook.com/v21.0/#{phone_number.waba_id}/message_templates"

    case Req.get(url,
           headers: [{"Authorization", "Bearer #{phone_number.access_token}"}],
           params: [limit: 250]
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        # Decode body if it's a string (Req sometimes doesn't auto-decode)
        data =
          case body do
            b when is_binary(b) -> Jason.decode!(b)
            map when is_map(map) -> map
            _ -> %{}
          end

        case data do
          %{"data" => templates} ->
            Enum.each(templates, fn t -> upsert_template(t, phone_number) end)
            length(templates)

          _ ->
            Logger.error(
              "Template sync unexpected body structure for WABA #{phone_number.waba_id}: #{inspect(data)}"
            )

            0
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error(
          "Template sync failed for WABA #{phone_number.waba_id}: HTTP #{status} - #{inspect(body)}"
        )

        0

      {:error, reason} ->
        Logger.error(
          "Template sync request failed for WABA #{phone_number.waba_id}: #{inspect(reason)}"
        )

        0
    end
  end

  defp upsert_template(meta_template, phone_number) do
    status = meta_template["status"]

    # Auto-delete DISABLED templates (if not referenced by campaigns)
    if status == "DISABLED" do
      case get_by_meta_id(meta_template["id"]) do
        # Not in DB, nothing to delete
        nil ->
          :ok

        existing ->
          try do
            case Repo.delete(existing) do
              {:ok, _} ->
                Logger.info("Auto-deleted DISABLED template: #{meta_template["name"]}")

              {:error, changeset} ->
                Logger.warning(
                  "Could not delete DISABLED template #{meta_template["name"]}: #{inspect(changeset.errors)}"
                )
            end
          rescue
            Ecto.ConstraintError ->
              # Template is still referenced by a campaign, just update status instead
              Logger.warning(
                "Template #{meta_template["name"]} is referenced by campaigns, updating status only"
              )

              update_template(existing, %{status: "DISABLED"})
          end
      end
    else
      attrs = %{
        meta_template_id: meta_template["id"],
        name: meta_template["name"],
        status: status,
        language: meta_template["language"],
        category: meta_template["category"],
        components: meta_template["components"],
        phone_number_id: phone_number.id,
        phone_display_name: phone_number.display_name || phone_number.mobile_number || "Unknown"
      }

      case get_by_meta_id(meta_template["id"]) do
        nil ->
          case create_template(attrs) do
            {:ok, _} ->
              :ok

            {:error, changeset} ->
              Logger.error(
                "Failed to create template #{meta_template["name"]}: #{inspect(changeset.errors)}"
              )
          end

        existing ->
          case update_template(existing, attrs) do
            {:ok, _} ->
              :ok

            {:error, changeset} ->
              Logger.error(
                "Failed to update template #{meta_template["name"]}: #{inspect(changeset.errors)}"
              )
          end
      end
    end
  end

  @doc """
  Create a cloned template via Meta API.
  """
  def create_clone(original_template, new_name, components, language, waba_id, access_token) do
    url = "https://graph.facebook.com/v21.0/#{waba_id}/message_templates"

    payload = %{
      name: new_name,
      language: language,
      category: original_template.category || "MARKETING",
      components: components
    }

    case Req.post(url,
           json: payload,
           headers: [{"Authorization", "Bearer #{access_token}"}]
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        # Save the new template locally
        create_template(%{
          meta_template_id: body["id"],
          name: new_name,
          status: "PENDING",
          language: language,
          category: original_template.category,
          components: components
        })

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end
end
