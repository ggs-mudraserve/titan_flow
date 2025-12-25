defmodule TitanFlow.Campaigns.Campaign do
  @moduledoc """
  Schema for marketing campaigns.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias TitanFlow.Templates.Template

  schema "campaigns" do
    field :name, :string
    field :status, :string, default: "draft"
    field :total_records, :integer, default: 0
    field :csv_path, :string

    # Store selected phone and template IDs as arrays (LEGACY - for backwards compatibility)
    field :phone_ids, {:array, :integer}, default: []
    field :template_ids, {:array, :integer}, default: []

    # NEW: Explicit phone-template mapping
    # Structure: [%{phone_id: 1, template_ids: [101, 102]}, ...]
    field :senders_config, {:array, :map}, default: []

    # Tracking fields - updated via webhooks
    field :sent_count, :integer, default: 0
    field :delivered_count, :integer, default: 0
    field :read_count, :integer, default: 0
    field :replied_count, :integer, default: 0
    field :failed_count, :integer, default: 0
    field :started_at, :naive_datetime
    field :completed_at, :naive_datetime

    # Deduplication settings
    field :dedup_window_days, :integer, default: 0
    field :skipped_count, :integer, default: 0

    # Error tracking
    field :error_message, :string

    belongs_to :primary_template, Template
    belongs_to :fallback_template, Template

    timestamps()
  end

  @required_fields [:name]
  @optional_fields [
    :status,
    :total_records,
    :csv_path,
    :primary_template_id,
    :fallback_template_id,
    :phone_ids,
    :template_ids,
    :senders_config,
    :sent_count,
    :delivered_count,
    :read_count,
    :replied_count,
    :failed_count,
    :started_at,
    :completed_at,
    :dedup_window_days,
    :skipped_count,
    :error_message
  ]

  def changeset(campaign, attrs) do
    campaign
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:primary_template_id)
    |> foreign_key_constraint(:fallback_template_id)
  end
end
