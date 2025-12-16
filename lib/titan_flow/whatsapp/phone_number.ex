defmodule TitanFlow.WhatsApp.PhoneNumber do
  @moduledoc """
  Schema for WhatsApp phone numbers.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "phone_numbers" do
    field :waba_id, :string
    field :phone_number_id, :string
    field :mobile_number, :string
    field :app_id, :string
    field :app_secret, :string
    field :display_name, :string
    field :access_token, :string
    field :quality_rating, :string, default: "GREEN"
    field :daily_limit, :string
    field :is_warmup_active, :boolean, default: false
    field :warmup_started_at, :utc_datetime
    field :system_prompt, :string, default: "You are a helpful assistant. Keep answers short."

    timestamps()
  end

  @required_fields [:phone_number_id, :waba_id]
  @optional_fields [:display_name, :access_token, :quality_rating, :daily_limit, 
                    :is_warmup_active, :warmup_started_at, :system_prompt, :app_id,
                    :mobile_number, :app_secret]

  def changeset(phone_number, attrs) do
    phone_number
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> unique_constraint(:phone_number_id)
  end
end
