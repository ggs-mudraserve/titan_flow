defmodule TitanFlowWeb.DateTimeHelpers do
  @moduledoc """
  Helper functions for datetime formatting in IST (Indian Standard Time).
  All times are stored in UTC and converted to IST (UTC+5:30) for display.
  """

  # 5 hours 30 minutes in seconds
  @ist_offset_seconds 5 * 3600 + 30 * 60

  @doc """
  Convert UTC datetime to IST and format for display.
  """
  def format_datetime(nil), do: "-"

  def format_datetime(datetime) do
    datetime
    |> to_ist()
    |> Calendar.strftime("%b %d, %Y %H:%M")
  end

  @doc """
  Format datetime with seconds.
  """
  def format_datetime_with_seconds(nil), do: "-"

  def format_datetime_with_seconds(datetime) do
    datetime
    |> to_ist()
    |> Calendar.strftime("%b %d, %Y %H:%M:%S")
  end

  @doc """
  Format time only (HH:MM).
  """
  def format_time(nil), do: "-"

  def format_time(datetime) do
    datetime
    |> to_ist()
    |> Calendar.strftime("%H:%M")
  end

  @doc """
  Format short date and time (Mon DD, HH:MM).
  """
  def format_short_datetime(nil), do: "-"

  def format_short_datetime(datetime) do
    datetime
    |> to_ist()
    |> Calendar.strftime("%b %d, %H:%M")
  end

  @doc """
  Format short date (Mon DD).
  """
  def format_short_date(nil), do: "-"

  def format_short_date(datetime) do
    datetime
    |> to_ist()
    |> Calendar.strftime("%b %d")
  end

  @doc """
  Format for 12-hour with AM/PM.
  """
  def format_12_hour(nil), do: "-"

  def format_12_hour(datetime) do
    datetime
    |> to_ist()
    |> Calendar.strftime("%b %d, %I:%M %p")
  end

  @doc """
  Format for tables (MM/DD/YYYY, HH:MM:SS).
  """
  def format_table_datetime(nil), do: "-"

  def format_table_datetime(datetime) do
    datetime
    |> to_ist()
    |> Calendar.strftime("%m/%d/%Y, %H:%M:%S")
  end

  @doc """
  Convert UTC datetime to IST (UTC+5:30).
  """
  def to_ist(nil), do: nil

  def to_ist(%DateTime{} = datetime) do
    DateTime.add(datetime, @ist_offset_seconds, :second)
  end

  def to_ist(%NaiveDateTime{} = naive) do
    naive
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.add(@ist_offset_seconds, :second)
  end

  @doc """
  Get current time in IST.
  """
  def now_ist do
    DateTime.utc_now()
    |> DateTime.add(@ist_offset_seconds, :second)
  end
end
