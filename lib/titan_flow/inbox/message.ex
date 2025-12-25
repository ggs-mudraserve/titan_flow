defmodule TitanFlow.Inbox.Message do
  @moduledoc """
  Schema for inbox messages.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias TitanFlow.Inbox.Conversation

  schema "messages" do
    # "inbound" or "outbound"
    field :direction, :string
    field :content, :string
    field :message_type, :string, default: "text"
    field :meta_message_id, :string
    field :status, :string
    field :template_name, :string
    field :is_ai_generated, :boolean, default: false

    belongs_to :conversation, Conversation

    timestamps()
  end

  def changeset(message, attrs) do
    message
    |> cast(attrs, [
      :conversation_id,
      :direction,
      :content,
      :message_type,
      :meta_message_id,
      :status,
      :template_name,
      :is_ai_generated
    ])
    |> validate_required([:conversation_id, :direction])
    |> validate_inclusion(:direction, ["inbound", "outbound"])
  end
end
