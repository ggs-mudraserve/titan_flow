defmodule TitanFlow.Campaigns.Importer do
  @moduledoc """
  Handles massive CSV imports efficiently using streaming and batch inserts.
  
  Supports multiple file formats for faster uploads:
  - Plain CSV (.csv)
  - GZIP compressed CSV (.gz) - Best compression, 70-80% smaller
  - ZIP archive (.zip) - Windows-friendly, extracts first CSV file
  
  Optimized for speed with:
  - Streaming CSV parsing (no full file load into memory)
  - Streaming decompression via system commands
  - Large batch inserts (5,000 records per batch)
  - Minimal database roundtrips
  """

  require Logger
  alias TitanFlow.Repo

  # Define CSV parser
  NimbleCSV.define(CSVParser, separator: ",", escape: "\"")

  # Batch size for database inserts
  # PostgreSQL limit is 65535 parameters. With 7 fields per contact, max is ~9,300
  # Using 5000 as safe value with good performance
  @batch_size 5000

  @doc """
  Import contacts from a CSV, GZIP, or ZIP file into a campaign.
  
  Automatically detects file type and decompresses on-the-fly.
  
  OPTIMIZED: Uses streaming + chunked batch inserts for maximum speed.
  Expected performance: 5,000-10,000 contacts/second on typical hardware.
  """
  @doc """
  Import contacts from a CSV, GZIP, or ZIP file into a campaign.
  
  Automatically detects file type and decompresses on-the-fly.
  Performs batch deduplication against contact_history if enabled.
  
  OPTIMIZED: Uses streaming + chunked batch inserts for maximum speed.
  """
  @spec import_csv(String.t(), integer()) :: {:ok, integer()} | {:error, term()}
  def import_csv(file_path, campaign_id) do
    campaign = TitanFlow.Campaigns.get_campaign!(campaign_id)
    import_csv_with_dedup(file_path, campaign, fn _ -> :ok end)
  end

  @doc """
  Import CSV with progress callback for tracking large imports.
  """
  @spec import_csv_with_progress(String.t(), integer(), (integer() -> any())) ::
          {:ok, integer()} | {:error, term()}
  def import_csv_with_progress(file_path, campaign_id, progress_fn) do
    campaign = TitanFlow.Campaigns.get_campaign!(campaign_id)
    import_csv_with_dedup(file_path, campaign, progress_fn)
  end

  defp import_csv_with_dedup(file_path, campaign, progress_fn) do
    start_time = System.monotonic_time(:millisecond)
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    dedup_window = campaign.dedup_window_days || 0
    cutoff_date = if dedup_window > 0 do
      NaiveDateTime.add(now, -dedup_window * 86400, :second)
    else
      nil
    end

    try do
      {inserted_count, skipped_count} =
        file_path
        |> file_stream()
        |> CSVParser.parse_stream(skip_headers: true)
        |> Stream.map(fn row -> row_to_contact(row, campaign.id, now) end)
        |> Stream.chunk_every(@batch_size)
        |> Enum.reduce({0, 0}, fn batch, {acc_inserted, acc_skipped} ->
          # Filter duplicates if window is active
          {valid_batch, batch_skipped} = 
            if cutoff_date do
              filter_duplicates(batch, cutoff_date)
            else
              {batch, 0}
            end
            
          # Insert valid contacts
          inserted = 
            if valid_batch != [] do
              {count, _} = Repo.insert_all("contacts", valid_batch, on_conflict: :nothing)
              count
            else
              0
            end
            
          total_inserted = acc_inserted + inserted
          total_skipped = acc_skipped + batch_skipped
          
          # Report progress (total processed records)
          progress_fn.(total_inserted + total_skipped)
          
          {total_inserted, total_skipped}
        end)

      # Update campaign with final counts
      TitanFlow.Campaigns.update_campaign(campaign, %{
        total_records: inserted_count,
        skipped_count: skipped_count
      })

      elapsed_ms = System.monotonic_time(:millisecond) - start_time
      total_processed = inserted_count + skipped_count
      rate = if elapsed_ms > 0, do: round(total_processed / elapsed_ms * 1000), else: 0
      
      file_type = detect_file_type(file_path)
      Logger.info("#{file_type} Import: #{inserted_count} inserted, #{skipped_count} skipped in #{elapsed_ms}ms (#{rate}/sec)")

      {:ok, inserted_count}
    rescue
      e in File.Error ->
        {:error, {:file_error, e.reason}}

      e ->
        Logger.error("CSV Import failed: #{Exception.message(e)}")
        {:error, {:import_failed, Exception.message(e)}}
    end
  end

  defp filter_duplicates(batch, cutoff_date) do
    # Extract phone numbers from batch
    phones = Enum.map(batch, & &1.phone)
    
    # Query contact_history for recently contacted phones
    import Ecto.Query
    
    recent_phones = 
      from(h in "contact_history",
        where: h.phone_number in ^phones,
        where: h.last_sent_at >= ^cutoff_date,
        select: h.phone_number
      )
      |> Repo.all()
      |> MapSet.new()
      
    # Identify valid and skipped contacts
    {valid, skipped} = Enum.split_with(batch, fn contact -> 
      not MapSet.member?(recent_phones, contact.phone)
    end)
    
    {valid, length(skipped)}
  end

  # Private Functions

  defp detect_file_type(file_path) do
    cond do
      String.ends_with?(file_path, ".gz") -> "GZIP"
      String.ends_with?(file_path, ".zip") -> "ZIP"
      true -> "CSV"
    end
  end

  # Returns a stream that handles CSV, GZIP, and ZIP files
  defp file_stream(file_path) do
    cond do
      String.ends_with?(file_path, ".gz") ->
        Logger.info("Detected GZIP file, using streaming decompression")
        gzip_stream(file_path)
        
      String.ends_with?(file_path, ".zip") ->
        Logger.info("Detected ZIP file, extracting CSV content")
        zip_stream(file_path)
        
      true ->
        File.stream!(file_path, read_ahead: 100_000)
    end
  end

  # Stream GZIP decompression using system command for efficiency
  defp gzip_stream(path) do
    Stream.resource(
      fn ->
        port = Port.open({:spawn, "gzip -d -c #{path}"}, [:binary, :exit_status, :use_stdio])
        {port, ""}
      end,
      fn {port, buffer} ->
        receive do
          {^port, {:data, data}} ->
            combined = buffer <> data
            lines = String.split(combined, "\n")
            {complete_lines, [new_buffer]} = Enum.split(lines, -1)
            {complete_lines, {port, new_buffer}}
            
          {^port, {:exit_status, 0}} ->
            if buffer != "" do
              {[buffer], {port, ""}}
            else
              {:halt, {port, ""}}
            end
            
          {^port, {:exit_status, status}} ->
            Logger.error("gzip decompression failed with status #{status}")
            {:halt, {port, ""}}
        after
          30_000 ->
            Logger.error("gzip decompression timed out")
            {:halt, {port, ""}}
        end
      end,
      fn {port, _buffer} ->
        try do
          Port.close(port)
        rescue
          _ -> :ok
        end
      end
    )
  end

  # Stream ZIP extraction - extracts first CSV file from archive
  # Uses unzip -p to pipe content to stdout
  defp zip_stream(path) do
    # First, find the CSV file inside the ZIP
    csv_filename = find_csv_in_zip(path)
    
    if csv_filename do
      Logger.info("Found CSV in ZIP: #{csv_filename}")
      
      Stream.resource(
        fn ->
          # unzip -p extracts to stdout
          port = Port.open({:spawn, "unzip -p #{path} \"#{csv_filename}\""}, [:binary, :exit_status, :use_stdio])
          {port, ""}
        end,
        fn {port, buffer} ->
          receive do
            {^port, {:data, data}} ->
              combined = buffer <> data
              lines = String.split(combined, "\n")
              {complete_lines, [new_buffer]} = Enum.split(lines, -1)
              {complete_lines, {port, new_buffer}}
              
            {^port, {:exit_status, 0}} ->
              if buffer != "" do
                {[buffer], {port, ""}}
              else
                {:halt, {port, ""}}
              end
              
            {^port, {:exit_status, status}} ->
              Logger.error("unzip extraction failed with status #{status}")
              {:halt, {port, ""}}
          after
            30_000 ->
              Logger.error("unzip extraction timed out")
              {:halt, {port, ""}}
          end
        end,
        fn {port, _buffer} ->
          try do
            Port.close(port)
          rescue
            _ -> :ok
          end
        end
      )
    else
      Logger.error("No CSV file found in ZIP archive")
      # Return empty stream
      Stream.map([], & &1)
    end
  end

  # Find the first CSV file inside a ZIP archive
  defp find_csv_in_zip(path) do
    case System.cmd("unzip", ["-l", path], stderr_to_stdout: true) do
      {output, 0} ->
        # Parse unzip -l output to find .csv files
        # Output format: "  Length      Date    Time    Name"
        # Example line: "   707919  2025-12-16 08:02   tata 16 Dec_vid.csv"
        output
        |> String.split("\n")
        |> Enum.find_value(fn line ->
          # Use regex to extract filename (everything after the time field)
          # Pattern: capture everything after "HH:MM   " until end of line
          case Regex.run(~r/\d{2}:\d{2}\s+(.+\.csv)\s*$/i, line) do
            [_, filename] -> String.trim(filename)
            _ -> nil
          end
        end)
        
      {error, _} ->
        Logger.error("Failed to list ZIP contents: #{error}")
        nil
    end
  end

  defp row_to_contact(row, campaign_id, timestamp) do
    # Row format: [phone, media_url, var1, var2, ...]
    case row do
      [phone, media_url | variable_values] ->
        variables =
          variable_values
          |> Enum.with_index(1)
          |> Enum.reduce(%{}, fn {value, index}, acc ->
            Map.put(acc, "var#{index}", value)
          end)

        variables = Map.put(variables, "media_url", media_url)

        %{
          phone: phone,
          name: nil,
          variables: variables,
          campaign_id: campaign_id,
          is_blacklisted: false,
          inserted_at: timestamp,
          updated_at: timestamp
        }

      [phone] ->
        %{
          phone: phone,
          name: nil,
          variables: %{},
          campaign_id: campaign_id,
          is_blacklisted: false,
          inserted_at: timestamp,
          updated_at: timestamp
        }
    end
  end
end
