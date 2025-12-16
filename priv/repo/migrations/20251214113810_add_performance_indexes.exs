defmodule TitanFlow.Repo.Migrations.AddPerformanceIndexes do
  use Ecto.Migration

  @doc """
  Adds critical performance indexes identified in the performance review.
  
  These indexes significantly improve:
  - Dashboard stats queries (campaign_id + status)
  - Reply attribution (recipient_phone + sent_at)
  - Time-based analytics (sent_at)
  - Contact lookups (campaign_id + phone)
  """
  def change do
    # Composite index for stats queries - used by get_realtime_stats
    # Dramatically improves: "SELECT ... WHERE campaign_id = ? GROUP BY status"
    create index(:message_logs, [:campaign_id, :status])
    
    # Index for reply lookups - used by record_reply
    # Improves: "SELECT ... WHERE recipient_phone = ? ORDER BY sent_at DESC"
    create index(:message_logs, [:recipient_phone, :sent_at])
    
    # Index for time-based stats - used by dashboard hourly/daily charts
    # Improves: "SELECT ... WHERE sent_at >= ? GROUP BY DATE(sent_at)"
    create index(:message_logs, [:sent_at])
    
    # Composite index for contact lookups
    # Improves: "SELECT ... WHERE campaign_id = ? AND phone = ?"
    create index(:contacts, [:campaign_id, :phone])
  end
end
