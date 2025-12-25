defmodule TitanFlow.Inbox.Conversation do
  @moduledoc """
  Schema for inbox conversations.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias TitanFlow.WhatsApp.PhoneNumber
  alias TitanFlow.Inbox.Message

  schema "conversations" do
    field :contact_phone, :string
    field :contact_name, :string
    field :last_message_at, :utc_datetime
    field :last_message_preview, :string
    field :unread_count, :integer, default: 0
    field :is_ai_paused, :boolean, default: false
    field :status, :string, default: "open"

    belongs_to :phone_number, PhoneNumber
    has_many :messages, Message

    timestamps()
  end

  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [
      :contact_phone,
      :contact_name,
      :phone_number_id,
      :last_message_at,
      :last_message_preview,
      :unread_count,
      :is_ai_paused,
      :status
    ])
    |> validate_required([:contact_phone])
  end
end
