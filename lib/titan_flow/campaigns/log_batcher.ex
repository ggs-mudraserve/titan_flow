defmodule TitanFlow.Campaigns.LogBatcher do
  @moduledoc """
  GenServer "Janitor" that flushes Redis buffers to PostgreSQL every 2 seconds.

  ## Buffers:
  - `buffer:message_logs` → `message_logs` table (via insert_all)
  - `buffer:contact_history` → `contact_history` table (via raw SQL upsert)
  - `buffer:contact_status` → `campaign_contact_status` table (via raw SQL upsert)

  ## Key Features:
  - Transforms JSON string keys to atoms
  - Parses ISO8601 strings to DateTime structs
  - Handles decode failures gracefully (dead letter logging)
  - Drains buffers on graceful shutdown
  - Alerts if buffer grows beyond 50K entries
  """
  use GenServer

  require Logger

  alias TitanFlow.Repo
  alias TitanFlow.Campaigns.MessageLog

  @flush_interval_ms 2_000
  @batch_size 1_000
  @buffer_alert_threshold 50_000

  @message_log_fields ~w(
    meta_message_id campaign_id contact_id recipient_phone 
    template_name phone_number_id status error_code 
    error_message sent_at inserted_at updated_at
  )a

  # Fields that should be parsed as DateTime (utc_datetime in schema)
  @utc_datetime_fields [:sent_at]

  # Fields that should be parsed as NaiveDateTime (Ecto timestamps)
  @naive_datetime_fields [:inserted_at, :updated_at]

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def flush_contact_status_now do
    GenServer.call(__MODULE__, :flush_contact_status, 30_000)
  end

  # --- Server Callbacks ---

  @impl true
  def init(_opts) do
    Logger.info("LogBatcher started, flushing every #{@flush_interval_ms}ms")
    schedule_tick()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    # Check buffer sizes and alert if too large
    check_buffer_sizes()

    # Flush buffers
    flush_message_logs()
    flush_contact_history()
    flush_contact_status()

    schedule_tick()
    {:noreply, state}
  end

  @impl true
  def handle_call(:flush_contact_status, _from, state) do
    count = flush_contact_status()
    {:reply, {:ok, count}, state}
  end

  @impl true
  def terminate(reason, _state) do
    Logger.info("LogBatcher shutting down (#{inspect(reason)}), draining buffers...")

    # Drain all remaining entries
    drain_buffer(:message_logs)
    drain_buffer(:contact_history)
    drain_buffer(:contact_status)

    Logger.info("LogBatcher drain complete")
    :ok
  end

  # --- Private Functions ---

  defp schedule_tick do
    Process.send_after(self(), :tick, @flush_interval_ms)
  end

  defp check_buffer_sizes do
    case Redix.command(:redix, ["LLEN", "buffer:message_logs"]) do
      {:ok, len} when len > @buffer_alert_threshold ->
        Logger.error("CRITICAL: buffer:message_logs at #{len} entries! DB may be struggling.")

      _ ->
        :ok
    end

    case Redix.command(:redix, ["LLEN", "buffer:contact_history"]) do
      {:ok, len} when len > @buffer_alert_threshold ->
        Logger.error("CRITICAL: buffer:contact_history at #{len} entries! DB may be struggling.")

      _ ->
        :ok
    end

    case Redix.command(:redix, ["LLEN", "buffer:contact_status"]) do
      {:ok, len} when len > @buffer_alert_threshold ->
        Logger.error("CRITICAL: buffer:contact_status at #{len} entries! DB may be struggling.")

      _ ->
        :ok
    end
  end

  # --- Message Logs Flush ---

  defp flush_message_logs do
    alias TitanFlow.Campaigns.Metrics

    Metrics.measure_log_flush(:message_logs, fn ->
      case Redix.command(:redix, ["LPOP", "buffer:message_logs", @batch_size]) do
        {:ok, nil} ->
          0

        {:ok, []} ->
          0

        {:ok, raw_entries} when is_list(raw_entries) ->
          entries = transform_message_logs(raw_entries)

          if length(entries) > 0 do
            case Repo.insert_all(MessageLog, entries, on_conflict: :nothing) do
              {count, _} ->
                Logger.debug("LogBatcher: Inserted #{count} message logs")
                count

              error ->
                Logger.error("LogBatcher: Failed to insert message logs: #{inspect(error)}")
                0
            end
          else
            0
          end

        {:error, reason} ->
          Logger.error("LogBatcher: Redis LPOP failed: #{inspect(reason)}")
          0
      end
    end)
  end

  defp transform_message_logs(raw_entries) do
    raw_entries
    |> Enum.map(&decode_and_transform_log/1)
    |> Enum.reject(&is_nil/1)
  end

  defp decode_and_transform_log(json_string) do
    case Jason.decode(json_string) do
      {:ok, map} ->
        transform_log_map(map)

      {:error, reason} ->
        Logger.error("LogBatcher: Failed to decode message log JSON: #{inspect(reason)}")
        nil
    end
  end

  defp transform_log_map(map) do
    # Convert string keys to atoms (only whitelisted fields)
    # Parse datetime strings to DateTime structs
    for {k, v} <- map,
        atom_key = safe_to_atom(k),
        atom_key != nil,
        atom_key in @message_log_fields,
        into: %{} do
      {atom_key, parse_value(atom_key, v)}
    end
  end

  defp safe_to_atom(key) when is_binary(key) do
    try do
      String.to_existing_atom(key)
    rescue
      ArgumentError -> nil
    end
  end

  defp safe_to_atom(key) when is_atom(key), do: key

  # Parse DateTime for utc_datetime fields (like sent_at)
  # Parse DateTime for utc_datetime fields (like sent_at)
  # NOTE: Ecto :utc_datetime expects NO microseconds, so we truncate to :second
  defp parse_value(key, value) when key in @utc_datetime_fields and is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> DateTime.truncate(dt, :second)
      _ -> nil
    end
  end

  # Parse NaiveDateTime for timestamps fields (inserted_at, updated_at)
  # NOTE: Ecto :naive_datetime expects NO microseconds, so we truncate to :second
  defp parse_value(key, value) when key in @naive_datetime_fields and is_binary(value) do
    # Strip the Z suffix if present, then parse
    clean_value = String.replace(value, "Z", "")

    case NaiveDateTime.from_iso8601(clean_value) do
      {:ok, ndt} -> NaiveDateTime.truncate(ndt, :second)
      _ -> nil
    end
  end

  defp parse_value(_key, value), do: value

  # --- Contact History Flush (Raw SQL) ---

  defp flush_contact_history do
    alias TitanFlow.Campaigns.Metrics

    Metrics.measure_log_flush(:contact_history, fn ->
      case Redix.command(:redix, ["LPOP", "buffer:contact_history", @batch_size]) do
        {:ok, nil} ->
          0

        {:ok, []} ->
          0

        {:ok, raw_entries} when is_list(raw_entries) ->
          entries = transform_contact_history(raw_entries)

          if length(entries) > 0 do
            execute_contact_history_upsert(entries)
            length(entries)
          else
            0
          end

        {:error, reason} ->
          Logger.error("LogBatcher: Redis LPOP for contact_history failed: #{inspect(reason)}")
          0
      end
    end)
  end

  defp flush_contact_status do
    alias TitanFlow.Campaigns.Metrics

    Metrics.measure_log_flush(:contact_status, fn ->
      case Redix.command(:redix, ["LPOP", "buffer:contact_status", @batch_size]) do
        {:ok, nil} ->
          0

        {:ok, []} ->
          0

        {:ok, raw_entries} when is_list(raw_entries) ->
          entries = transform_contact_status(raw_entries)

          if length(entries) > 0 do
            execute_contact_status_upsert(entries)
            length(entries)
          else
            0
          end

        {:error, reason} ->
          Logger.error("LogBatcher: Redis LPOP for contact_status failed: #{inspect(reason)}")
          0
      end
    end)
  end

  defp transform_contact_history(raw_entries) do
    raw_entries
    |> Enum.map(&decode_contact_history_entry/1)
    |> Enum.reject(&is_nil/1)
  end

  defp decode_contact_history_entry(json_string) do
    case Jason.decode(json_string) do
      {:ok, map} ->
        %{
          phone_number: Map.get(map, "phone_number"),
          last_sent_at: parse_datetime_string(Map.get(map, "last_sent_at")),
          last_campaign_id: Map.get(map, "last_campaign_id"),
          inserted_at: parse_datetime_string(Map.get(map, "inserted_at")),
          updated_at: parse_datetime_string(Map.get(map, "updated_at"))
        }

      {:error, reason} ->
        Logger.error("LogBatcher: Failed to decode contact_history JSON: #{inspect(reason)}")
        nil
    end
  end

  defp parse_datetime_string(nil), do: nil

  defp parse_datetime_string(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_datetime_string(value), do: value

  defp execute_contact_history_upsert(entries) do
    # Build parameterized placeholders: ($1, $2, $3, $4, $5), ($6, $7, $8, $9, $10), ...
    {placeholders, flat_params} =
      entries
      |> Enum.with_index()
      |> Enum.map_reduce([], fn {entry, idx}, acc ->
        base = idx * 5
        placeholder = "($#{base + 1}, $#{base + 2}, $#{base + 3}, $#{base + 4}, $#{base + 5})"

        params = [
          entry.phone_number,
          entry.last_sent_at,
          entry.last_campaign_id,
          entry.inserted_at,
          entry.updated_at
        ]

        {placeholder, acc ++ params}
      end)

    values_clause = Enum.join(placeholders, ", ")

    sql = """
    INSERT INTO contact_history (phone_number, last_sent_at, last_campaign_id, inserted_at, updated_at)
    VALUES #{values_clause}
    ON CONFLICT (phone_number) DO UPDATE SET
      last_sent_at = GREATEST(contact_history.last_sent_at, EXCLUDED.last_sent_at),
      last_campaign_id = EXCLUDED.last_campaign_id,
      updated_at = EXCLUDED.updated_at
    """

    case Repo.query(sql, flat_params) do
      {:ok, result} ->
        Logger.debug("LogBatcher: Upserted #{result.num_rows} contact history entries")

      {:error, reason} ->
        Logger.error("LogBatcher: Failed to upsert contact_history: #{inspect(reason)}")
    end
  end

  defp transform_contact_status(raw_entries) do
    raw_entries
    |> Enum.map(&decode_contact_status_entry/1)
    |> Enum.reject(&is_nil/1)
  end

  defp decode_contact_status_entry(json_string) do
    case Jason.decode(json_string) do
      {:ok, map} ->
        %{
          campaign_id: Map.get(map, "campaign_id"),
          contact_id: Map.get(map, "contact_id"),
          last_status: Map.get(map, "last_status"),
          last_error_code: Map.get(map, "last_error_code"),
          inserted_at: parse_datetime_string(Map.get(map, "inserted_at")),
          updated_at: parse_datetime_string(Map.get(map, "updated_at"))
        }

      {:error, reason} ->
        Logger.error("LogBatcher: Failed to decode contact_status JSON: #{inspect(reason)}")
        nil
    end
  end

  defp execute_contact_status_upsert(entries) do
    {placeholders, flat_params} =
      entries
      |> Enum.with_index()
      |> Enum.map_reduce([], fn {entry, idx}, acc ->
        base = idx * 6

        placeholder =
          "($#{base + 1}, $#{base + 2}, $#{base + 3}, $#{base + 4}, $#{base + 5}, $#{base + 6})"

        params = [
          entry.campaign_id,
          entry.contact_id,
          entry.last_status,
          entry.last_error_code,
          entry.inserted_at,
          entry.updated_at
        ]

        {placeholder, acc ++ params}
      end)

    values_clause = Enum.join(placeholders, ", ")

    sql = """
    INSERT INTO campaign_contact_status (campaign_id, contact_id, last_status, last_error_code, inserted_at, updated_at)
    VALUES #{values_clause}
    ON CONFLICT (campaign_id, contact_id) DO UPDATE SET
      last_status = EXCLUDED.last_status,
      last_error_code = EXCLUDED.last_error_code,
      updated_at = EXCLUDED.updated_at
    """

    case Repo.query(sql, flat_params) do
      {:ok, result} ->
        Logger.debug("LogBatcher: Upserted #{result.num_rows} contact status entries")

      {:error, reason} ->
        Logger.error("LogBatcher: Failed to upsert contact_status: #{inspect(reason)}")
    end
  end

  # --- Buffer Drain on Shutdown ---

  defp drain_buffer(:message_logs) do
    case Redix.command(:redix, ["LLEN", "buffer:message_logs"]) do
      {:ok, 0} ->
        :ok

      {:ok, len} ->
        Logger.info("LogBatcher: Draining #{len} message logs...")
        drain_message_logs_loop()

      _ ->
        :ok
    end
  end

  defp drain_buffer(:contact_history) do
    case Redix.command(:redix, ["LLEN", "buffer:contact_history"]) do
      {:ok, 0} ->
        :ok

      {:ok, len} ->
        Logger.info("LogBatcher: Draining #{len} contact history entries...")
        drain_contact_history_loop()

      _ ->
        :ok
    end
  end

  defp drain_buffer(:contact_status) do
    case Redix.command(:redix, ["LLEN", "buffer:contact_status"]) do
      {:ok, 0} ->
        :ok

      {:ok, len} ->
        Logger.info("LogBatcher: Draining #{len} contact status entries...")
        drain_contact_status_loop()

      _ ->
        :ok
    end
  end

  defp drain_message_logs_loop do
    case Redix.command(:redix, ["LPOP", "buffer:message_logs", @batch_size]) do
      {:ok, nil} ->
        :ok

      {:ok, []} ->
        :ok

      {:ok, raw_entries} when is_list(raw_entries) and length(raw_entries) > 0 ->
        entries = transform_message_logs(raw_entries)

        if length(entries) > 0 do
          Repo.insert_all(MessageLog, entries, on_conflict: :nothing)
        end

        drain_message_logs_loop()

      _ ->
        :ok
    end
  end

  defp drain_contact_history_loop do
    case Redix.command(:redix, ["LPOP", "buffer:contact_history", @batch_size]) do
      {:ok, nil} ->
        :ok

      {:ok, []} ->
        :ok

      {:ok, raw_entries} when is_list(raw_entries) and length(raw_entries) > 0 ->
        entries = transform_contact_history(raw_entries)

        if length(entries) > 0 do
          execute_contact_history_upsert(entries)
        end

        drain_contact_history_loop()

      _ ->
        :ok
    end
  end

  defp drain_contact_status_loop do
    case Redix.command(:redix, ["LPOP", "buffer:contact_status", @batch_size]) do
      {:ok, nil} ->
        :ok

      {:ok, []} ->
        :ok

      {:ok, raw_entries} when is_list(raw_entries) and length(raw_entries) > 0 ->
        entries = transform_contact_status(raw_entries)

        if length(entries) > 0 do
          execute_contact_status_upsert(entries)
        end

        drain_contact_status_loop()

      _ ->
        :ok
    end
  end
end
