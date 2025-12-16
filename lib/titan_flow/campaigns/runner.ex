defmodule TitanFlow.Campaigns.Runner do
  @moduledoc """
  Orchestrates campaign message sending by distributing contacts across sender phone numbers.

  Streams contacts from the database and pushes them to per-sender Redis queues
  using round-robin distribution for load balancing.
  """

  import Ecto.Query
  alias TitanFlow.Repo

  @batch_size 1000

  @doc """
  Start a campaign by distributing contacts to sender queues.

  ## Parameters
  - `campaign_id` - ID of the campaign to run
  - `phone_number_ids` - List of sender phone number IDs for round-robin distribution

  ## Returns
  - `{:ok, total_queued}` - Number of contacts queued
  - `{:error, reason}` - On failure

  ## Example
      iex> Runner.start_campaign(123, ["phone_1", "phone_2", "phone_3"])
      {:ok, 50000}
  """
  @spec start_campaign(integer(), [String.t()]) :: {:ok, integer()} | {:error, term()}
  def start_campaign(campaign_id, phone_number_ids) when is_list(phone_number_ids) do
    if Enum.empty?(phone_number_ids) do
      {:error, :no_phone_numbers}
    else
      redix_config = Application.get_env(:titan_flow, :redix)
      
      {:ok, conn} = Redix.start_link(
        host: redix_config[:host],
        port: redix_config[:port],
        password: redix_config[:password]
      )

      try do
        # Repo.stream must be called within a transaction
        {:ok, total_queued} = Repo.transaction(fn ->
          campaign_id
          |> stream_contacts()
          |> Stream.chunk_every(@batch_size)
          |> Stream.with_index()
          |> Enum.reduce(0, fn {batch, batch_index}, acc ->
            # Round-robin: assign this batch to a phone number
            phone_index = rem(batch_index, length(phone_number_ids))
            phone_number_id = Enum.at(phone_number_ids, phone_index)
            
            queued = push_batch_to_redis(conn, phone_number_id, batch)
            acc + queued
          end)
        end, timeout: :infinity)

        {:ok, total_queued}
      after
        Redix.stop(conn)
      end
    end
  end

  @doc """
  Get the queue length for a sender phone number.
  """
  @spec queue_length(String.t()) :: {:ok, integer()} | {:error, term()}
  def queue_length(phone_number_id) do
    redix_config = Application.get_env(:titan_flow, :redix)
    
    {:ok, conn} = Redix.start_link(
      host: redix_config[:host],
      port: redix_config[:port],
      password: redix_config[:password]
    )

    try do
      queue_name = queue_key(phone_number_id)
      {:ok, length} = Redix.command(conn, ["LLEN", queue_name])
      {:ok, length}
    after
      Redix.stop(conn)
    end
  end

  @doc """
  Complete a campaign by re-queuing contacts that were missed.
  Finds contacts NOT in message_logs and pushes them to the queue.
  """
  @spec complete_campaign(integer(), String.t()) :: {:ok, integer()} | {:error, term()}
  def complete_campaign(campaign_id, phone_number_id) do
    require Logger
    Logger.info("Runner: Completing campaign #{campaign_id} - finding missing contacts")
    
    redix_config = Application.get_env(:titan_flow, :redix)
    
    {:ok, conn} = Redix.start_link(
      host: redix_config[:host],
      port: redix_config[:port],
      password: redix_config[:password]
    )

    try do
      # Stream contacts that are NOT in message_logs
      {:ok, total_queued} = Repo.transaction(fn ->
        campaign_id
        |> stream_missing_contacts()
        |> Stream.chunk_every(@batch_size)
        |> Enum.reduce(0, fn batch, acc ->
          queued = push_batch_to_redis(conn, phone_number_id, batch)
          Logger.info("Runner: Queued #{queued} missing contacts")
          acc + queued
        end)
      end, timeout: :infinity)

      Logger.info("Runner: Campaign #{campaign_id} completion - queued #{total_queued} missing contacts")
      {:ok, total_queued}
    after
      Redix.stop(conn)
    end
  end

  defp stream_missing_contacts(campaign_id) do
    # Find contacts where there's no corresponding message_log entry
    query =
      from c in "contacts",
        left_join: m in "message_logs",
          on: m.contact_id == c.id and m.campaign_id == c.campaign_id,
        where: c.campaign_id == ^campaign_id and c.is_blacklisted == false,
        where: is_nil(m.id),
        select: %{
          id: c.id,
          phone: c.phone,
          name: c.name,
          variables: c.variables
        }

    Repo.stream(query, max_rows: @batch_size)
  end

  # Private Functions

  defp stream_contacts(campaign_id) do
    query =
      from c in "contacts",
        where: c.campaign_id == ^campaign_id and c.is_blacklisted == false,
        select: %{
          id: c.id,
          phone: c.phone,
          name: c.name,
          variables: c.variables
        }

    Repo.stream(query, max_rows: @batch_size)
  end

  defp push_batch_to_redis(conn, phone_number_id, contacts) do
    queue_name = queue_key(phone_number_id)

    # Build pipeline of RPUSH commands
    commands =
      Enum.map(contacts, fn contact ->
        payload = Jason.encode!(%{
          contact_id: contact.id,
          phone: contact.phone,
          name: contact.name,
          variables: contact.variables
        })

        ["RPUSH", queue_name, payload]
      end)

    # Execute all commands in a single network call
    case Redix.pipeline(conn, commands) do
      {:ok, _results} ->
        length(contacts)

      {:error, reason} ->
        # Log error but continue processing
        require Logger
        Logger.error("Failed to push batch to Redis: #{inspect(reason)}")
        0
    end
  end

  defp queue_key(phone_number_id) do
    "queue:sending:#{phone_number_id}"
  end
end
