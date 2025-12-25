defmodule TitanFlow.Settings do
  @moduledoc """
  Context for managing global application settings.
  """
  alias TitanFlow.Repo
  alias TitanFlow.Settings.ConfigEntry

  @doc """
  Gets a global config value by key. Returns default if not found.
  """
  def get_value(key, default \\ nil) do
    case Repo.get(ConfigEntry, key) do
      nil -> default
      entry -> entry.value
    end
  end

  @doc """
  Sets a global config value. Creates or updates.
  """
  def set_value(key, value) do
    entry = Repo.get(ConfigEntry, key) || %ConfigEntry{key: key}

    entry
    |> ConfigEntry.changeset(%{value: value})
    |> Repo.insert_or_update()
  end
end
