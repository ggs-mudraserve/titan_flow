defmodule TitanFlow.WhatsApp do
  @moduledoc """
  Context for WhatsApp operations including phone number management.
  """

  import Ecto.Query
  alias TitanFlow.Repo
  alias TitanFlow.WhatsApp.PhoneNumber

  # Phone Number CRUD

  @doc """
  List all phone numbers.
  """
  def list_phone_numbers do
    Repo.all(from p in PhoneNumber, order_by: [desc: p.inserted_at])
  end

  @doc """
  Count phone numbers efficiently (single COUNT query, no data loaded).
  """
  def count_phone_numbers do
    Repo.aggregate(PhoneNumber, :count)
  end

  @doc """
  Get a phone number by ID.
  """
  def get_phone_number!(id), do: Repo.get!(PhoneNumber, id)

  @doc """
  Get a phone number by phone_number_id.
  """
  def get_by_phone_number_id(phone_number_id) do
    Repo.get_by(PhoneNumber, phone_number_id: phone_number_id)
  end

  @doc """
  Create a new phone number.
  """
  def create_phone_number(attrs \\ %{}) do
    %PhoneNumber{}
    |> PhoneNumber.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Update a phone number.
  """
  def update_phone_number(%PhoneNumber{} = phone_number, attrs) do
    phone_number
    |> PhoneNumber.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Delete a phone number.
  """
  def delete_phone_number(%PhoneNumber{} = phone_number) do
    Repo.delete(phone_number)
  end

  @doc """
  Get a changeset for a phone number.
  """
  def change_phone_number(%PhoneNumber{} = phone_number, attrs \\ %{}) do
    PhoneNumber.changeset(phone_number, attrs)
  end

  @doc """
  Sync phone number with Meta API to verify token and update quality rating.
  """
  def sync_phone_number(%PhoneNumber{} = phone_number) do
    url = "https://graph.facebook.com/v21.0/#{phone_number.phone_number_id}"

    case Req.get(url, headers: [{"Authorization", "Bearer #{phone_number.access_token}"}]) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        quality_rating = get_in(body, ["quality_rating"]) || "GREEN"
        display_name = get_in(body, ["verified_name"]) || get_in(body, ["display_phone_number"])

        update_phone_number(phone_number, %{
          quality_rating: quality_rating,
          display_name: display_name
        })

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @doc """
  Sync templates for a specific phone number (wrapper for Templates.sync_templates_for_waba).
  """
  def sync_templates(phone_id) do
    phone_number = get_phone_number!(phone_id)
    TitanFlow.Templates.sync_templates_for_waba(phone_number)
  end
end
