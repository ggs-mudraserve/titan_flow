defmodule TitanFlow.Stats do
  @moduledoc """
  Statistics queries for dashboard KPIs and charts.
  Uses Postgres message_logs table for analytics.
  """

  import Ecto.Query
  alias TitanFlow.Repo
  alias TitanFlow.Campaigns.MessageLog

  @doc """
  Get dashboard KPIs for today.
  Returns: %{sent_today: int, delivered_pct: float, failed: int}
  
  OPTIMIZED: Uses single query with conditional aggregation instead of 3 separate queries.
  """
  def get_today_kpis do
    today_start = Date.utc_today() |> DateTime.new!(~T[00:00:00], "Etc/UTC")

    try do
      # Single optimized query with conditional aggregation
      sql = """
      SELECT 
        COUNT(*) as sent_today,
        COUNT(*) FILTER (WHERE status IN ('delivered', 'read')) as delivered,
        COUNT(*) FILTER (WHERE status = 'failed') as failed
      FROM message_logs
      WHERE sent_at >= $1
      """
      
      case Repo.query(sql, [today_start]) do
        {:ok, %{rows: [[sent_today, delivered, failed]]}} ->
          sent_today = sent_today || 0
          delivered = delivered || 0
          failed = failed || 0
          
          delivered_pct = if sent_today > 0, do: Float.round(delivered / sent_today * 100, 1), else: 0.0

          %{
            sent_today: sent_today,
            delivered_pct: delivered_pct,
            failed: failed
          }
          
        _ ->
          %{sent_today: 0, delivered_pct: 0.0, failed: 0}
      end
    rescue
      _ ->
        # Return zero data if database is unavailable
        %{sent_today: 0, delivered_pct: 0.0, failed: 0}
    end
  end

  @doc """
  Get dashboard summary stats with a single optimized query.
  Returns: %{active_count: int, total_sent: int, total_campaigns: int}
  
  This replaces multiple queries with one aggregate query for the dashboard.
  """
  def get_dashboard_summary do
    alias TitanFlow.Campaigns.Campaign
    
    try do
      result = Repo.one(
        from c in Campaign,
        select: %{
          active_count: fragment("COUNT(*) FILTER (WHERE status = 'running')"),
          total_sent: coalesce(sum(c.sent_count), 0),
          total_campaigns: count(c.id)
        }
      )
      
      %{
        active_count: result.active_count || 0,
        total_sent: result.total_sent || 0,
        total_campaigns: result.total_campaigns || 0
      }
    rescue
      _ ->
        %{active_count: 0, total_sent: 0, total_campaigns: 0}
    end
  end

  @doc """
  Get hourly message volume for charting.
  Returns list of %{hour, today, yesterday} maps.
  """
  def get_hourly_volume do
    today = Date.utc_today()
    yesterday = Date.utc_today() |> Date.add(-1)

    try do
      # Query hourly counts for today
      today_rows = Repo.all(
        from m in MessageLog,
        where: fragment("DATE(?)", m.sent_at) == ^today,
        group_by: fragment("EXTRACT(HOUR FROM ?)", m.sent_at),
        select: {fragment("EXTRACT(HOUR FROM ?)::integer", m.sent_at), count(m.id)}
      )

      # Query hourly counts for yesterday
      yesterday_rows = Repo.all(
        from m in MessageLog,
        where: fragment("DATE(?)", m.sent_at) == ^yesterday,
        group_by: fragment("EXTRACT(HOUR FROM ?)", m.sent_at),
        select: {fragment("EXTRACT(HOUR FROM ?)::integer", m.sent_at), count(m.id)}
      )

      # Convert to maps for easy lookup
      today_map = Map.new(today_rows || [], fn {hour, cnt} -> {hour, cnt} end)
      yesterday_map = Map.new(yesterday_rows || [], fn {hour, cnt} -> {hour, cnt} end)

      # Build 24-hour data
      for hour <- 0..23 do
        %{
          hour: hour,
          today: Map.get(today_map, hour, 0),
          yesterday: Map.get(yesterday_map, hour, 0)
        }
      end
    rescue
      _ ->
        # Return empty data on error
        for hour <- 0..23 do
          %{
            hour: hour,
            today: 0,
            yesterday: 0
          }
        end
    end
  end

  @doc """
  Get daily activity for the last N days.
  Returns list of daily stats including sent, delivered, read, failed per day.
  """
  def get_daily_activity(days \\ 7) do
    # Use IST timezone offset (UTC+5:30)
    ist_offset = 5 * 3600 + 30 * 60
    now_ist = DateTime.utc_now() |> DateTime.add(ist_offset, :second)
    today_ist = DateTime.to_date(now_ist)
    
    try do
      # Query daily stats for last N days
      start_date = Date.add(today_ist, -(days - 1))
      
      # Get all messages from the date range with IST conversion
      query = from m in MessageLog,
        where: fragment("(? AT TIME ZONE 'UTC' AT TIME ZONE 'Asia/Kolkata')::date >= ?", m.sent_at, ^start_date),
        group_by: fragment("(? AT TIME ZONE 'UTC' AT TIME ZONE 'Asia/Kolkata')::date", m.sent_at),
        select: {
          fragment("(? AT TIME ZONE 'UTC' AT TIME ZONE 'Asia/Kolkata')::date", m.sent_at),
          count(m.id),
          sum(fragment("CASE WHEN ? IN ('sent', 'delivered', 'read') THEN 1 ELSE 0 END", m.status)),
          sum(fragment("CASE WHEN ? IN ('delivered', 'read') THEN 1 ELSE 0 END", m.status)),
          sum(fragment("CASE WHEN ? = 'read' THEN 1 ELSE 0 END", m.status)),
          sum(fragment("CASE WHEN ? = 'failed' THEN 1 ELSE 0 END", m.status))
        }
      
      rows = Repo.all(query)
      stats_map = Map.new(rows, fn {date, total, sent, delivered, read, failed} ->
        {date, %{
          total: total || 0,
          sent: sent || 0,
          delivered: delivered || 0,
          read: read || 0,
          failed: failed || 0
        }}
      end)
      
      # Build list for each day
      for day_offset <- (days - 1)..0 do
        date = Date.add(today_ist, -day_offset)
        stats = Map.get(stats_map, date, %{total: 0, sent: 0, delivered: 0, read: 0, failed: 0})
        
        success_pct = if stats.total > 0 do
          round((stats.total - stats.failed) / stats.total * 100)
        else
          0
        end
        
        %{
          date: date,
          day_name: Calendar.strftime(date, "%a"),
          day_number: date.day,
          is_today: date == today_ist,
          total: stats.total,
          sent: stats.sent,
          delivered: stats.delivered,
          read: stats.read,
          failed: stats.failed,
          success_pct: success_pct
        }
      end
    rescue
      _ ->
        # Return empty data on error
        for day_offset <- (days - 1)..0 do
          date = Date.add(today_ist, -day_offset)
          %{
            date: date,
            day_name: Calendar.strftime(date, "%a"),
            day_number: date.day,
            is_today: date == today_ist,
            total: 0,
            sent: 0,
            delivered: 0,
            read: 0,
            failed: 0,
            success_pct: 0
          }
        end
    end
  end

  @doc """
  Get monthly summary stats for the current month.
  Returns: active_days, avg_per_day, peak_day, total_read, total_failed
  """
  def get_monthly_summary do
    # Use IST timezone
    ist_offset = 5 * 3600 + 30 * 60
    now_ist = DateTime.utc_now() |> DateTime.add(ist_offset, :second)
    today_ist = DateTime.to_date(now_ist)
    month_start = Date.beginning_of_month(today_ist)
    
    try do
      # Query daily totals for current month
      query = from m in MessageLog,
        where: fragment("(? AT TIME ZONE 'UTC' AT TIME ZONE 'Asia/Kolkata')::date >= ?", m.sent_at, ^month_start),
        group_by: fragment("(? AT TIME ZONE 'UTC' AT TIME ZONE 'Asia/Kolkata')::date", m.sent_at),
        select: {
          fragment("(? AT TIME ZONE 'UTC' AT TIME ZONE 'Asia/Kolkata')::date", m.sent_at),
          count(m.id),
          sum(fragment("CASE WHEN ? = 'read' THEN 1 ELSE 0 END", m.status)),
          sum(fragment("CASE WHEN ? = 'failed' THEN 1 ELSE 0 END", m.status))
        }
      
      rows = Repo.all(query)
      
      if Enum.empty?(rows) do
        %{
          active_days: 0,
          avg_per_day: 0,
          peak_day: 0,
          total_read: 0,
          total_failed: 0
        }
      else
        daily_totals = Enum.map(rows, fn {_date, total, _read, _failed} -> total end)
        total_read = Enum.sum(Enum.map(rows, fn {_date, _total, read, _failed} -> read || 0 end))
        total_failed = Enum.sum(Enum.map(rows, fn {_date, _total, _read, failed} -> failed || 0 end))
        
        active_days = length(rows)
        total_sent = Enum.sum(daily_totals)
        avg_per_day = if active_days > 0, do: round(total_sent / active_days), else: 0
        peak_day = Enum.max(daily_totals, fn -> 0 end)
        
        %{
          active_days: active_days,
          avg_per_day: avg_per_day,
          peak_day: peak_day,
          total_read: total_read,
          total_failed: total_failed
        }
      end
    rescue
      _ ->
        %{
          active_days: 0,
          avg_per_day: 0,
          peak_day: 0,
          total_read: 0,
          total_failed: 0
        }
    end
  end

  @doc """
  Get global stats for dashboard bottom cards.
  Returns: total_messages, contacts_count, campaigns_count, templates_count, numbers_count, success_pct
  """
  def get_global_stats do
    alias TitanFlow.Campaigns.Campaign
    alias TitanFlow.Templates.Template
    alias TitanFlow.WhatsApp.PhoneNumber
    
    try do
      # Total messages from all campaigns
      total_messages = Repo.one(
        from c in Campaign,
        select: coalesce(sum(c.sent_count), 0) + coalesce(sum(c.failed_count), 0)
      ) || 0
      
      # Distinct contacts (unique recipient phones)
      contacts_count = Repo.one(
        from m in MessageLog,
        select: count(fragment("DISTINCT ?", m.recipient_phone))
      ) || 0
      
      # Campaigns count
      campaigns_count = Repo.aggregate(Campaign, :count) || 0
      
      # Templates count
      templates_count = Repo.aggregate(Template, :count) || 0
      
      # Phone numbers count
      numbers_count = Repo.aggregate(PhoneNumber, :count) || 0
      
      # Overall success rate
      total_sent = Repo.one(from c in Campaign, select: coalesce(sum(c.sent_count), 0)) || 0
      total_failed = Repo.one(from c in Campaign, select: coalesce(sum(c.failed_count), 0)) || 0
      total_processed = total_sent + total_failed
      success_pct = if total_processed > 0 do
        round(total_sent / total_processed * 100)
      else
        0
      end
      
      %{
        total_messages: total_messages,
        contacts_count: contacts_count,
        campaigns_count: campaigns_count,
        templates_count: templates_count,
        numbers_count: numbers_count,
        success_pct: success_pct
      }
    rescue
      _ ->
        %{
          total_messages: 0,
          contacts_count: 0,
          campaigns_count: 0,
          templates_count: 0,
          numbers_count: 0,
          success_pct: 0
        }
    end
  end

  @doc """
  Format a number in Indian numbering system (e.g., 1,22,98,497).
  """
  def format_indian(num) when is_integer(num) and num < 1000 do
    Integer.to_string(num)
  end
  
  def format_indian(num) when is_integer(num) do
    num_str = Integer.to_string(num)
    len = String.length(num_str)
    
    # Last 3 digits
    last_three = String.slice(num_str, (len - 3)..(len - 1))
    rest = String.slice(num_str, 0..(len - 4))
    
    # Split rest into groups of 2
    rest_formatted = rest
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(2)
    |> Enum.map(&Enum.reverse/1)
    |> Enum.reverse()
    |> Enum.map(&Enum.join/1)
    |> Enum.join(",")
    
    if rest_formatted == "" do
      last_three
    else
      "#{rest_formatted},#{last_three}"
    end
  end
  
  def format_indian(num), do: Integer.to_string(round(num))

  @doc """
  Get current month name and year.
  """
  def get_current_month_label do
    ist_offset = 5 * 3600 + 30 * 60
    now_ist = DateTime.utc_now() |> DateTime.add(ist_offset, :second)
    Calendar.strftime(now_ist, "%B %Y")
  end
end

