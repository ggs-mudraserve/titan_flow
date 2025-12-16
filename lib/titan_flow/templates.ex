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

  def list_templates do
    Repo.all(from t in Template, order_by: [desc: t.inserted_at])
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

  defp sync_templates_for_waba(phone_number) do

    url = "https://graph.facebook.com/v21.0/#{phone_number.waba_id}/message_templates"
    
    case Req.get(url, 
      headers: [{"Authorization", "Bearer #{phone_number.access_token}"}],
      params: [limit: 250]
    ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        # Decode body if it's a string (Req sometimes doesn't auto-decode)
        data = case body do
          b when is_binary(b) -> Jason.decode!(b)
          map when is_map(map) -> map
          _ -> %{}
        end

        case data do
          %{"data" => templates} ->
            Enum.each(templates, fn t -> upsert_template(t, phone_number) end)
            length(templates)
          _ ->
             Logger.error("Template sync unexpected body structure for WABA #{phone_number.waba_id}: #{inspect(data)}")
             0
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("Template sync failed for WABA #{phone_number.waba_id}: HTTP #{status} - #{inspect(body)}")
        0

      {:error, reason} ->
        Logger.error("Template sync request failed for WABA #{phone_number.waba_id}: #{inspect(reason)}")
        0
    end
  end

  defp upsert_template(meta_template, phone_number) do
    attrs = %{
      meta_template_id: meta_template["id"],
      name: meta_template["name"],
      status: meta_template["status"],
      language: meta_template["language"],
      category: meta_template["category"],
      components: meta_template["components"],
      phone_number_id: phone_number.id,
      phone_display_name: phone_number.display_name || phone_number.mobile_number || "Unknown"
    }

    case get_by_meta_id(meta_template["id"]) do
      nil -> 
        case create_template(attrs) do
          {:ok, _} -> :ok
          {:error, changeset} -> 
            Logger.error("Failed to create template #{meta_template["name"]}: #{inspect(changeset.errors)}")
        end
      existing -> 
        case update_template(existing, attrs) do
          {:ok, _} -> :ok
          {:error, changeset} ->
            Logger.error("Failed to update template #{meta_template["name"]}: #{inspect(changeset.errors)}")
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
