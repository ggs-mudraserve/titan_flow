defmodule TitanFlow.Campaigns.ContactHistory do
  @moduledoc """
  Schema for the contact_history table - a lightweight lookup table for instant deduplication.
  
  This table maintains a single row per phone number with the most recent contact timestamp.
  Much more efficient than scanning message_logs for deduplication checks.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:phone_number, :string, autogenerate: false}
  schema "contact_history" do
    field :last_sent_at, :utc_datetime
    field :last_campaign_id, :integer

    timestamps()
  end

  @required_fields [:phone_number, :last_sent_at]
  @optional_fields [:last_campaign_id]

  def changeset(contact_history, attrs) do
    contact_history
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
  end
end
