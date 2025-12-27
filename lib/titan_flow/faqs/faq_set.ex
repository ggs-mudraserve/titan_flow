defmodule TitanFlow.Faqs.FaqSet do
  @moduledoc """
  FAQ set (e.g., Bajaj, Tata, Incred).
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias TitanFlow.Faqs.{FaqAnswer, FaqQuestion}

  schema "faq_sets" do
    field :name, :string
    field :slug, :string
    field :active, :boolean, default: true

    has_many :answers, FaqAnswer
    has_many :questions, FaqQuestion

    timestamps()
  end

  def changeset(faq_set, attrs) do
    faq_set
    |> cast(attrs, [:name, :slug, :active])
    |> validate_required([:name, :slug])
    |> unique_constraint(:slug)
  end
end
