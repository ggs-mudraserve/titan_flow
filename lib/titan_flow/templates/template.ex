defmodule TitanFlow.Templates.Template do
  @moduledoc """
  Schema for WhatsApp message templates.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "templates" do
    field :meta_template_id, :string
    field :name, :string
    field :status, :string
    field :language, :string
    field :category, :string
    field :components, {:array, :map}
    field :health_score, :string
    field :phone_display_name, :string
    
    belongs_to :phone_number, TitanFlow.WhatsApp.PhoneNumber

    timestamps()
  end

  @required_fields [:name]
  @optional_fields [:meta_template_id, :status, :language, :category, :components, :health_score, :phone_number_id, :phone_display_name]

  def changeset(template, attrs) do
    template
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
  end
end
