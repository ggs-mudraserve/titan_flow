# Connection Pool Sizing Guide (6A)

## Current Configuration

| Component | Setting | Value | Location |
|-----------|---------|-------|----------|
| Ecto Pool | `pool_size` | 30 | runtime.exs:51 |
| Ecto Pool | `queue_target` | 5000ms | runtime.exs:52 |
| Ecto Pool | `checkout_timeout` | 15000ms | runtime.exs:55 |
| Finch HTTP | `size` | 500 | application.ex:21 |
| Supavisor | Mode | Transaction | port 6543 |

## Sizing Guidelines

### Ecto Pool Size Formula

```
pool_size = (CPU cores on DB × 2) + 1 per node
```

For your setup (assumed 4-8 core DB):
- **Single node**: 10-20 connections
- **With 30 pool**: You have headroom for multiple nodes or burst

### When to Increase Pool Size

| Symptom | Metric | Action |
|---------|--------|--------|
| `queue_time > 100ms` frequent | Telemetry logs | Consider increasing |
| "DBConnection.ConnectionError" | Error logs | Increase pool_size |
| `[METRICS] Q: >1000ms` | MetricsReporter | Urgent - increase pool |

### When to Decrease Pool Size

| Symptom | Action |
|---------|--------|
| DB CPU > 80% during campaigns | Decrease pool or throttle MPS |
| Supabase billing spike | Lower pool_size |

## Monitoring Commands

### Check Metrics Log
```bash
# Watch real-time metrics (every 30s)
grep "[METRICS]" /path/to/logs
```

### Check Pool Saturation Alerts
```bash
grep "ALERT.*Pool Saturation" /path/to/logs
```

## Production Recommendations

| Environment | Ecto pool_size | Finch pool | Notes |
|-------------|----------------|------------|-------|
| Low traffic | 10 | 100 | Single campaign |
| Medium | 20-30 | 300 | 2-3 concurrent campaigns |
| High | 40-50 | 500 | 5+ campaigns or high MPS |

> **Warning**: Pool size is shared across all features (web, campaigns, webhooks). Don't set too low.
