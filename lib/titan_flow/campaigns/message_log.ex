defmodule TitanFlow.Campaigns.MessageLog do
  @moduledoc """
  Schema for tracking individual message statuses from webhooks.
  Links messages to campaigns for aggregated reporting.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias TitanFlow.Campaigns.Campaign

  schema "message_logs" do
    field :meta_message_id, :string
    field :phone_number_id, :string
    field :recipient_phone, :string
    field :status, :string, default: "sent"
    field :template_name, :string
    field :error_code, :string
    field :error_message, :string
    field :sent_at, :utc_datetime
    field :delivered_at, :utc_datetime
    field :read_at, :utc_datetime
    field :has_replied, :boolean, default: false

    belongs_to :campaign, Campaign
    # contact_id is optional - we may not always have it
    field :contact_id, :integer

    timestamps()
  end

  @required_fields [:meta_message_id]
  @optional_fields [
    :campaign_id,
    :contact_id,
    :phone_number_id,
    :recipient_phone,
    :template_name,
    :status,
    :error_code,
    :error_message,
    :sent_at,
    :delivered_at,
    :read_at,
    :has_replied
  ]

  def changeset(message_log, attrs) do
    message_log
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> unique_constraint(:meta_message_id)
  end
end
