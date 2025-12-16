# TitanFlow Performance & Code Review Report

**Date:** December 14, 2025  
**Reviewer:** AI Code Review Assistant  
**Scope:** Full codebase analysis covering performance, database interactions, code quality, and security

---

## Table of Contents

1. [Executive Summary](#executive-summary)
2. [Database Performance & Indexing](#1-database-performance--indexing)
3. [Database Interaction Patterns](#2-database-interaction-patterns)
4. [Page Load Performance](#3-page-load-performance)
5. [Redis Usage Patterns](#4-redis-usage-patterns)
6. [Code Quality & Structure](#5-code-quality--structure)
7. [Security Considerations](#6-security-considerations)
8. [Memory & Resource Optimization](#7-memory--resource-optimization)
9. [Implementation Plan](#8-implementation-plan)
10. [Migration Scripts](#9-migration-scripts)

---

## Executive Summary

The TitanFlow WhatsApp marketing platform is well-architected with good separation of concerns. The codebase follows Elixir/Phoenix best practices with proper use of contexts, LiveView, and OTP patterns. However, there are several areas where performance can be significantly improved:

### Key Findings

| Category | Severity | Count |
|----------|----------|-------|
| Missing Database Indexes | 🔴 High | 5 |
| N+1 Query Problems | 🟠 Medium | 3 |
| Duplicate Code | 🟡 Low | 4 |
| Dead Code | 🟡 Low | 4 |
| Security Issues | 🟠 Medium | 2 |

### Estimated Impact of Fixes

- **Dashboard Load Time:** 60-70% faster
- **Stats Queries:** 5-10x faster with proper indexes
- **Campaign Running:** 30% fewer DB operations
- **Webhook Processing:** 50% fewer DB roundtrips

---

## 1. Database Performance & Indexing

### 1.1 Missing Database Indexes

The current schema has basic indexes but lacks composite indexes for common query patterns.

#### Current Indexes (from migrations)

```
message_logs: meta_message_id (unique), campaign_id, contact_id, status
contacts: campaign_id, phone
campaigns: primary_template_id, fallback_template_id
```

#### Missing Indexes (CRITICAL)

| Table | Columns | Purpose | Priority |
|-------|---------|---------|----------|
| `message_logs` | `(campaign_id, status)` | Stats queries with status filtering | 🔴 HIGH |
| `message_logs` | `(recipient_phone, sent_at DESC)` | Reply attribution lookups | 🔴 HIGH |
| `message_logs` | `(sent_at)` | Time-based stats (hourly/daily) | 🔴 HIGH |
| `contacts` | `(campaign_id, id) WHERE is_blacklisted = false` | BufferManager unsent contacts | 🟠 MEDIUM |
| `message_logs` | `(recipient_phone, sent_at) WHERE status = 'sent'` | Deduplication queries | 🟠 MEDIUM |

#### Files Affected
- `lib/titan_flow/campaigns/message_tracking.ex` - lines 136-172 (get_realtime_stats)
- `lib/titan_flow/stats.ex` - lines 15-53, 59-103, 109-186
- `lib/titan_flow/campaigns/buffer_manager.ex` - lines 162-181

### 1.2 N+1 Query Problems

#### Problem 1: Dashboard Mount
**File:** `lib/titan_flow_web/live/dashboard_live.ex` (lines 9-26)

```elixir
# CURRENT: Loads ALL campaigns, then iterates
campaigns = Campaigns.list_campaigns()
active_campaigns = Enum.count(campaigns, fn c -> c.status == "running" end)
total_sent = Enum.reduce(campaigns, 0, fn c, acc -> acc + (c.sent_count || 0) end)
```

**SUGGESTED:**
```elixir
# Use aggregate query - single DB call
def get_dashboard_stats() do
  from(c in Campaign,
    select: %{
      active_count: fragment("COUNT(*) FILTER (WHERE status = 'running')"),
      total_sent: coalesce(sum(c.sent_count), 0),
      total_campaigns: count(c.id)
    }
  )
  |> Repo.one()
end
```

#### Problem 2: Campaigns List Without Pagination
**File:** `lib/titan_flow/campaigns.ex` (lines 41-46)

```elixir
# CURRENT: Loads ALL campaigns with preloads
def list_campaigns do
  Campaign
  |> order_by(desc: :inserted_at)
  |> Repo.all()
  |> Repo.preload([:primary_template, :fallback_template])
end
```

**SUGGESTED:**
```elixir
# Add pagination
def list_campaigns(page \\ 1, per_page \\ 25) do
  offset = (page - 1) * per_page
  
  query = from c in Campaign,
    order_by: [desc: c.inserted_at],
    limit: ^per_page,
    offset: ^offset,
    preload: [:primary_template, :fallback_template]
  
  entries = Repo.all(query)
  total = Repo.aggregate(Campaign, :count)
  
  %{entries: entries, page: page, total_pages: ceil(total / per_page), total: total}
end
```

#### Problem 3: Template Sync Sequential API Calls
**File:** `lib/titan_flow/templates.ex` (lines 49-61)

```elixir
# CURRENT: Sequential API calls
phone_numbers
|> Enum.map(&sync_templates_for_waba/1)
|> Enum.sum()
```

**SUGGESTED:**
```elixir
# Parallel API calls
phone_numbers
|> Task.async_stream(&sync_templates_for_waba/1, max_concurrency: 5, timeout: 30_000)
|> Enum.reduce(0, fn {:ok, count}, acc -> acc + count end)
```

### 1.3 Inefficient Stats Queries

#### Problem: Multiple Queries for Single Dashboard
**File:** `lib/titan_flow/stats.ex` (lines 15-53)

```elixir
# CURRENT: 3 separate database queries
sent_today = Repo.one(from m in MessageLog, where: ..., select: count(m.id))
delivered = Repo.one(from m in MessageLog, where: ..., select: count(m.id))
failed = Repo.one(from m in MessageLog, where: ..., select: count(m.id))
```

**SUGGESTED:**
```elixir
# Single query with conditional aggregation
def get_today_kpis do
  today_start = Date.utc_today() |> DateTime.new!(~T[00:00:00], "Etc/UTC")

  result = Repo.one(
    from m in MessageLog,
    where: m.sent_at >= ^today_start,
    select: %{
      sent_today: count(m.id),
      delivered: fragment("COUNT(*) FILTER (WHERE status IN ('delivered', 'read'))"),
      failed: fragment("COUNT(*) FILTER (WHERE status = 'failed')")
    }
  )

  delivered_pct = if result.sent_today > 0 do
    Float.round(result.delivered / result.sent_today * 100, 1)
  else
    0.0
  end

  %{
    sent_today: result.sent_today,
    delivered_pct: delivered_pct,
    failed: result.failed
  }
end
```

---

## 2. Database Interaction Patterns

### 2.1 Campaign Creation Flow

| Step | Current Implementation | DB Operations | Status |
|------|----------------------|---------------|--------|
| CSV Upload | Copy file to temp | 0 | ✅ Good |
| Create Campaign | `Repo.insert()` | 1 INSERT | ✅ Good |
| Import CSV | `Repo.insert_all()` batches of 5000 | Multiple bulk INSERTs | ✅ Good |
| Deduplication | LEFT JOIN query | 1 SELECT + 1 UPDATE_ALL | 🟡 Could optimize |

**Files:** 
- `lib/titan_flow_web/live/campaign_live/new.ex`
- `lib/titan_flow/campaigns/importer.ex`
- `lib/titan_flow/campaigns/sanitizer.ex`

### 2.2 Running Campaign Flow

| Step | Current | Issue | Suggestion |
|------|---------|-------|------------|
| BufferManager refill | LEFT JOIN to message_logs | Expensive join | Add `is_queued` flag on contacts |
| Pipeline dispatch | Fire-and-forget Task for record_sent | 1 INSERT per message | Batch inserts |
| Counter updates | Individual Redis commands | Many roundtrips | Use PIPELINE |

**File:** `lib/titan_flow/campaigns/buffer_manager.ex` (lines 162-181)

```elixir
# CURRENT: Expensive LEFT JOIN on every refill
defp fetch_unsent_contacts(campaign_id, after_id, limit) do
  query = from c in "contacts",
    left_join: m in "message_logs", 
      on: m.contact_id == c.id and m.campaign_id == c.campaign_id,
    where: c.campaign_id == ^campaign_id,
    where: c.id > ^after_id,
    where: c.is_blacklisted == false,
    where: is_nil(m.id),  # This requires scanning message_logs
    ...
end
```

**SUGGESTED APPROACH:**
1. Add `is_queued` boolean column to contacts table
2. Set `is_queued = true` when pushing to Redis
3. Filter by `is_queued = false` instead of LEFT JOIN

### 2.3 Webhook Processing Flow

| Step | Current DB Ops | Optimized DB Ops |
|------|---------------|-----------------|
| Status Update | 1 SELECT + 1 UPDATE | 1 UPDATE(ALL) |
| Record Reply | 1 SELECT + 1 UPDATE | 1 UPDATE_ALL |
| Inbox Message | 1 SELECT + 1 INSERT | 1 UPSERT |

**File:** `lib/titan_flow/campaigns/message_tracking.ex` (lines 81-94)

```elixir
# CURRENT: Two DB operations
case Repo.get_by(MessageLog, meta_message_id: meta_message_id) do
  nil -> {:ok, :not_tracked}
  log -> update_log_and_counters(log, ...)
end
```

**SUGGESTED:**
```elixir
# Single DB operation with RETURNING
{count, [updated_log]} = Repo.update_all(
  from(m in MessageLog,
    where: m.meta_message_id == ^meta_message_id,
    select: m
  ),
  [set: [status: ^status, delivered_at: ^timestamp]]
)

if count > 0 do
  update_counters(updated_log.campaign_id, updated_log.status, status)
end
```

---

## 3. Page Load Performance

### 3.1 LiveView Mount Optimizations

| Page | Current Issue | Suggested Fix |
|------|--------------|---------------|
| `/campaigns` | Loads all campaigns | Add pagination |
| `/dashboard` | Multiple stats queries | Single aggregate query |
| `/inbox` | Already paginated | ✅ Good |
| `/templates` | Loads all templates | Add pagination for large lists |

### 3.2 Polling Intervals

| Location | Current | Issue | Suggested |
|----------|---------|-------|-----------|
| CampaignsLive stats modal | 2 seconds | Too aggressive | 5 seconds or PubSub |
| BufferManager | 5 seconds | Reasonable | ✅ Good |

**File:** `lib/titan_flow_web/live/campaigns_live.ex` (line 218)

```elixir
# CURRENT
Process.send_after(self(), :tick, 2000)

# SUGGESTED
Process.send_after(self(), :tick, 5000)
```

### 3.3 Real-time Stats Alternative

Instead of polling, consider PubSub for real-time updates:

```elixir
# In MessageTracking after recording
Phoenix.PubSub.broadcast(TitanFlow.PubSub, "campaign:#{campaign_id}:stats", {:stats_updated, stats})

# In CampaignsLive mount
if connected?(socket) do
  Phoenix.PubSub.subscribe(TitanFlow.PubSub, "campaign:#{campaign_id}:stats")
end
```

---

## 4. Redis Usage Patterns

### 4.1 Counter Synchronization Issues

**Current State:**
- Counters stored in Redis during campaign
- Synced to Postgres only on completion
- **Risk:** Data loss if Redis restarts mid-campaign

**File:** `lib/titan_flow/campaigns/message_tracking.ex` (lines 237-258)

**SUGGESTED:**
```elixir
# Add periodic sync (every 5 minutes) during campaign
def schedule_periodic_sync(campaign_id) do
  Process.send_after(self(), {:sync_counters, campaign_id}, 5 * 60 * 1000)
end

def handle_info({:sync_counters, campaign_id}, state) do
  sync_counters_to_db(campaign_id)
  schedule_periodic_sync(campaign_id)
  {:noreply, state}
end
```

### 4.2 Redis Pipeline Usage

**Current:** Individual Redis commands
**Suggested:** Use pipelines for batch operations

```elixir
# CURRENT: Multiple roundtrips
Redix.command(:redix, ["INCR", "campaign:#{id}:sent_count"])
Redix.command(:redix, ["SET", "campaign:#{id}:last_sent", timestamp])

# SUGGESTED: Single roundtrip
Redix.pipeline(:redix, [
  ["INCR", "campaign:#{id}:sent_count"],
  ["SET", "campaign:#{id}:last_sent", timestamp]
])
```

---

## 5. Code Quality & Structure

### 5.1 Duplicated Code

| Function | Locations | Suggestion |
|----------|-----------|------------|
| `status_badge_class/1` | CampaignsLive (250), DashboardLive (72) | Extract to CoreComponents |
| `format_datetime/1` | Multiple LiveViews | Use DateTimeHelpers consistently |
| `progress_percent/1` | CampaignsLive (270-278) | Move to Campaign schema |
| `quality_badge_class/1` | CampaignLive.New (619-622) | Extract to CoreComponents |

**Suggested Helper Module:**

```elixir
# lib/titan_flow_web/helpers/ui_helpers.ex
defmodule TitanFlowWeb.UIHelpers do
  def status_badge_class(status) do
    base = "inline-flex items-center px-2.5 py-0.5 rounded-full text-xs font-medium"
    
    color_class = case status do
      "draft" -> "bg-amber-100 text-amber-800 dark:bg-amber-900/30 dark:text-amber-400"
      "pending" -> "bg-yellow-100 text-yellow-800 dark:bg-yellow-900/30 dark:text-yellow-400"
      "running" -> "bg-blue-100 text-blue-800 dark:bg-blue-900/30 dark:text-blue-400"
      "completed" -> "bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-400"
      "paused" -> "bg-gray-100 text-gray-800 dark:bg-gray-900/30 dark:text-gray-400"
      _ -> "bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-400"
    end
    
    "#{base} #{color_class}"
  end

  def quality_badge_class("GREEN"), do: "bg-green-100 text-green-700"
  def quality_badge_class("YELLOW"), do: "bg-yellow-100 text-yellow-700"
  def quality_badge_class("RED"), do: "bg-red-100 text-red-700"
  def quality_badge_class(_), do: "bg-gray-100 text-gray-700"
end
```

### 5.2 Dead Code

| Location | Function | Can Remove |
|----------|----------|------------|
| `message_tracking.ex:183-192` | `populate_redis_stats/2` | Yes |
| `message_tracking.ex:178-181` | `get_db_stats_struct/1` | Yes |
| `rate_limiter.ex:198-211` | `send_message/2` | Yes |
| `webhook_controller.ex:133-153` | `trigger_fallback_for_template/2` | Yes |

### 5.3 Missing Typespec/Documentation

These functions would benefit from typespecs:

- `TitanFlow.Stats` - All public functions
- `TitanFlow.Campaigns.Pipeline` - dispatch functions
- `TitanFlow.WhatsApp.Client` - Already has some, extend to all

### 5.4 Error Handling Improvements

**File:** `lib/titan_flow_web/controllers/webhook_controller.ex` (line 38)

```elixir
# CURRENT: Task.start with no error handling
Task.start(fn -> process_webhook(params) end)

# SUGGESTED: Add error reporting
Task.start(fn ->
  try do
    process_webhook(params)
  rescue
    e ->
      Logger.error("Webhook processing failed: #{Exception.message(e)}")
      # Optionally: Report to error tracking service
  end
end)
```

---

## 6. Security Considerations

### 6.1 Hardcoded Secrets (CRITICAL)

**File:** `config/runtime.exs`

| Line | Issue | Fix |
|------|-------|-----|
| 31-37 | Database password in code | Use `System.get_env("DATABASE_PASSWORD")` |
| 40-43 | Redis password in code | Use `System.get_env("REDIS_PASSWORD")` |
| 65 | Default admin PIN "123456" | Remove default, require ENV var |

**SUGGESTED:**
```elixir
# Database
config :titan_flow, TitanFlow.Repo,
  username: System.get_env("DATABASE_USER", "postgres"),
  password: System.fetch_env!("DATABASE_PASSWORD"),
  hostname: System.get_env("DATABASE_HOST", "localhost"),
  port: String.to_integer(System.get_env("DATABASE_PORT", "5432")),
  database: System.get_env("DATABASE_NAME", "titan_flow"),
  pool_size: String.to_integer(System.get_env("POOL_SIZE", "40"))

# Redis
config :titan_flow, :redix,
  host: System.get_env("REDIS_HOST", "localhost"),
  port: String.to_integer(System.get_env("REDIS_PORT", "6379")),
  password: System.get_env("REDIS_PASSWORD")

# Admin PIN (no default)
config :titan_flow, :admin_pin, System.fetch_env!("ADMIN_PIN")
```

### 6.2 Input Validation

All user inputs appear to be properly validated through Ecto changesets. ✅

### 6.3 Rate Limiting on Webhooks

Currently, webhook endpoint has no rate limiting. Consider adding:

```elixir
# In router.ex or as a plug
plug Hammer.Plug,
  rate_limit: {"webhooks", 1000, 60_000},  # 1000 requests per minute
  by: :ip
```

---

## 7. Memory & Resource Optimization

### 7.1 File Cleanup

**Issue:** Temporary CSV files are not cleaned up after import

**Files Affected:**
- `lib/titan_flow_web/live/campaign_live/new.ex` (line 119)
- `lib/titan_flow/campaigns.ex` (delete_campaign should clean up csv_path)

**SUGGESTED:**
```elixir
# In Campaigns.delete_campaign/1
def delete_campaign(%Campaign{} = campaign) do
  # Clean up CSV file if exists
  if campaign.csv_path && File.exists?(campaign.csv_path) do
    File.rm(campaign.csv_path)
  end
  
  Repo.delete(campaign)
end
```

### 7.2 Broadway Processor Tuning

**File:** `lib/titan_flow/campaigns/pipeline.ex` (lines 58-62)

```elixir
# CURRENT: 200 concurrent processors
processors: [
  default: [concurrency: 200]
]
```

Consider making this configurable based on system resources:

```elixir
processors: [
  default: [
    concurrency: Application.get_env(:titan_flow, :pipeline_concurrency, 200)
  ]
]
```

### 7.3 Database Connection Pool

**File:** `config/runtime.exs` (line 37)

Current pool size is 40, which seems reasonable for the workload. Monitor and adjust as needed.

---

## 8. Implementation Plan

### Phase 1: Critical Database Indexes (Day 1)
**Estimated Impact:** 5-10x faster stats queries

1. Create migration for performance indexes
2. Run migration in production during low-traffic period
3. Verify query plans with `EXPLAIN ANALYZE`

### Phase 2: Stats Query Optimization (Day 1-2)
**Estimated Impact:** 60% faster dashboard

1. Refactor `Stats.get_today_kpis/0` to single query
2. Add aggregate function to Campaigns context for dashboard
3. Update DashboardLive to use new functions

### Phase 3: Security Fixes (Day 2)
**Estimated Impact:** Production-ready security

1. Move all secrets to environment variables
2. Update deployment documentation
3. Remove default admin PIN

### Phase 4: Add Pagination (Day 2-3)
**Estimated Impact:** Scalability for growth

1. Add pagination to Campaigns.list_campaigns
2. Update CampaignsLive to handle pagination
3. Add pagination to Templates if needed

### Phase 5: Code Cleanup (Day 3-4)

1. Extract duplicate helper functions
2. Remove dead code
3. Add missing documentation

### Phase 6: Webhook Optimization (Day 4-5)

1. Refactor update_status to use UPDATE_ALL
2. Add error handling to webhook Task
3. Consider adding rate limiting

### Phase 7: Redis Improvements (Day 5)

1. Add periodic counter sync during campaigns
2. Implement Redis pipeline for batch operations

---

## 9. Migration Scripts

### 9.1 Performance Indexes Migration

```elixir
# priv/repo/migrations/YYYYMMDDHHMMSS_add_performance_indexes.exs
defmodule TitanFlow.Repo.Migrations.AddPerformanceIndexes do
  use Ecto.Migration
  
  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    # Composite index for stats queries (CONCURRENTLY to avoid locking)
    create index(:message_logs, [:campaign_id, :status], concurrently: true)
    
    # Index for reply lookups
    create index(:message_logs, [:recipient_phone, :sent_at], concurrently: true)
    
    # Index for time-based stats
    create index(:message_logs, [:sent_at], concurrently: true)
    
    # Partial index for unsent contacts (BufferManager)
    execute """
    CREATE INDEX CONCURRENTLY IF NOT EXISTS contacts_campaign_unsent_idx 
    ON contacts(campaign_id, id) 
    WHERE is_blacklisted = false
    """,
    "DROP INDEX IF EXISTS contacts_campaign_unsent_idx"
  end
end
```

### 9.2 Add is_queued Column (Optional Optimization)

```elixir
# priv/repo/migrations/YYYYMMDDHHMMSS_add_is_queued_to_contacts.exs
defmodule TitanFlow.Repo.Migrations.AddIsQueuedToContacts do
  use Ecto.Migration

  def change do
    alter table(:contacts) do
      add :is_queued, :boolean, default: false
    end
    
    create index(:contacts, [:campaign_id, :is_queued])
  end
end
```

---

## Summary Checklist

- [ ] **Phase 1:** Create and run index migration
- [ ] **Phase 2:** Refactor stats queries to single query pattern
- [ ] **Phase 3:** Move secrets to environment variables
- [ ] **Phase 4:** Add pagination to campaigns list
- [ ] **Phase 5:** Extract helper functions, remove dead code
- [ ] **Phase 6:** Optimize webhook update_status
- [ ] **Phase 7:** Add Redis pipeline usage and periodic sync

---

## Appendix: Files Modified Per Phase

### Phase 1 (Indexes)
- `priv/repo/migrations/XXXX_add_performance_indexes.exs` (new)

### Phase 2 (Stats)
- `lib/titan_flow/stats.ex`
- `lib/titan_flow/campaigns.ex`
- `lib/titan_flow_web/live/dashboard_live.ex`

### Phase 3 (Security)
- `config/runtime.exs`
- `.env.example` (new)
- `README.md` (update)

### Phase 4 (Pagination)
- `lib/titan_flow/campaigns.ex`
- `lib/titan_flow_web/live/campaigns_live.ex`

### Phase 5 (Cleanup)
- `lib/titan_flow_web/helpers/ui_helpers.ex` (new)
- `lib/titan_flow_web/live/campaigns_live.ex`
- `lib/titan_flow_web/live/dashboard_live.ex`
- `lib/titan_flow/campaigns/message_tracking.ex`
- `lib/titan_flow/whatsapp/rate_limiter.ex`
- `lib/titan_flow_web/controllers/webhook_controller.ex`

### Phase 6 (Webhooks)
- `lib/titan_flow/campaigns/message_tracking.ex`
- `lib/titan_flow_web/controllers/webhook_controller.ex`

### Phase 7 (Redis)
- `lib/titan_flow/campaigns/message_tracking.ex`
- `lib/titan_flow/campaigns/pipeline.ex`
