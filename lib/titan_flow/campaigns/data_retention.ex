defmodule TitanFlow.Campaigns.DataRetention do
  @moduledoc """
  Weekly data retention cleanup for message_logs and contact_history.

  Runs at midnight IST every week to keep tables small and queries fast.
  """

  use GenServer
  require Logger

  alias TitanFlow.Repo

  @message_logs_days 15
  @contact_history_days 30
  @ist_offset_seconds 19_800
  @min_delay_ms 1_000

  # Public API
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    schedule_next_run(1)
    {:ok, state}
  end

  @impl true
  def handle_info(:run_cleanup, state) do
    run_cleanup()
    schedule_next_run(7)
    {:noreply, state}
  end

  def run_cleanup do
    log_cutoff =
      DateTime.utc_now()
      |> DateTime.add(-@message_logs_days * 86_400, :second)

    history_cutoff =
      DateTime.utc_now()
      |> DateTime.add(-@contact_history_days * 86_400, :second)

    deleted_logs = delete_message_logs(log_cutoff)
    deleted_history = delete_contact_history(history_cutoff)

    Logger.info(
      "DataRetention: deleted #{deleted_logs} message_logs (<#{@message_logs_days}d) and #{deleted_history} contact_history (<#{@contact_history_days}d)"
    )

    :ok
  end

  defp delete_message_logs(cutoff) do
    case Repo.query(
           "DELETE FROM message_logs WHERE inserted_at < $1",
           [cutoff],
           timeout: 600_000
         ) do
      {:ok, %{num_rows: count}} ->
        count

      {:error, reason} ->
        Logger.error("DataRetention: Failed to delete message_logs: #{inspect(reason)}")
        0
    end
  end

  defp delete_contact_history(cutoff) do
    case Repo.query(
           "DELETE FROM contact_history WHERE last_sent_at < $1",
           [cutoff],
           timeout: 600_000
         ) do
      {:ok, %{num_rows: count}} ->
        count

      {:error, reason} ->
        Logger.error("DataRetention: Failed to delete contact_history: #{inspect(reason)}")
        0
    end
  end

  defp schedule_next_run(days_ahead) do
    now_utc = DateTime.utc_now()
    now_ist = DateTime.add(now_utc, @ist_offset_seconds, :second)
    ist_date = DateTime.to_date(now_ist)
    next_date = Date.add(ist_date, days_ahead)

    next_midnight_ist = NaiveDateTime.new!(next_date, ~T[00:00:00])
    next_midnight_utc = NaiveDateTime.add(next_midnight_ist, -@ist_offset_seconds, :second)

    diff_ms =
      NaiveDateTime.diff(next_midnight_utc, DateTime.to_naive(now_utc), :millisecond)

    delay_ms = max(diff_ms, @min_delay_ms)

    Logger.info(
      "DataRetention: Next cleanup scheduled in #{div(delay_ms, 1000)}s (midnight IST)"
    )

    Process.send_after(self(), :run_cleanup, delay_ms)
  end
end
