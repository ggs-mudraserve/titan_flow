defmodule TitanFlow.WhatsApp.PhoneCache do
  @moduledoc """
  ETS-based cache for phone_number_id -> db_id mappings.
  Eliminates repeated DB lookups for known phone numbers.

  Phone numbers rarely change, so infinite TTL is safe.
  Call invalidate/1 when a phone is deleted.
  """
  use GenServer
  require Logger

  @table_name :phone_id_cache

  # Client API

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc """
  Get DB ID for a phone_number_id (Meta's ID).
  Returns the database primary key ID, or nil if not found.

  First lookup hits ETS cache, on miss fetches from DB and caches.
  """
  def get_db_id(phone_number_id) when is_binary(phone_number_id) do
    case :ets.lookup(@table_name, phone_number_id) do
      [{^phone_number_id, db_id}] ->
        db_id

      [] ->
        # Cache miss - fetch from DB and cache
        case TitanFlow.WhatsApp.get_by_phone_number_id(phone_number_id) do
          nil ->
            Logger.warning("PhoneCache: Unknown phone_number_id: #{phone_number_id}")
            nil

          phone ->
            :ets.insert(@table_name, {phone_number_id, phone.id})
            Logger.debug("PhoneCache: Cached #{phone_number_id} -> #{phone.id}")
            phone.id
        end
    end
  end

  def get_db_id(phone_number_id) when is_integer(phone_number_id) do
    get_db_id(Integer.to_string(phone_number_id))
  end

  def get_db_id(_), do: nil

  @doc """
  Invalidate cache entry for a phone_number_id.
  Call this when a phone number is deleted or its ID changes.
  """
  def invalidate(phone_number_id) when is_binary(phone_number_id) do
    :ets.delete(@table_name, phone_number_id)
    Logger.debug("PhoneCache: Invalidated #{phone_number_id}")
    :ok
  end

  def invalidate(phone_number_id) when is_integer(phone_number_id) do
    invalidate(Integer.to_string(phone_number_id))
  end

  def invalidate(_), do: :ok

  @doc """
  Get cache statistics for monitoring.
  """
  def stats do
    %{
      size: :ets.info(@table_name, :size),
      memory: :ets.info(@table_name, :memory)
    }
  end

  # Server Callbacks

  @impl true
  def init(_) do
    table =
      :ets.new(@table_name, [
        :named_table,
        :set,
        :public,
        read_concurrency: true
      ])

    Logger.info("PhoneCache: Started with ETS table #{inspect(table)}")
    {:ok, %{}}
  end
end
