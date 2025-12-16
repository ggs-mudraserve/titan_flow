defmodule TitanFlow.Settings.ConfigEntry do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:key, :string, autogenerate: false}
  schema "global_configs" do
    field :value, :string
    timestamps()
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:key, :value])
    |> validate_required([:key, :value])
  end
end
