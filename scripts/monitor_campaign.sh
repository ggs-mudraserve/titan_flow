#!/usr/bin/env bash
set -euo pipefail

INTERVAL=5
OUT_FILE=""
DB_QUERY=0
QUEUE_KEY_LIMIT=500
QUEUE_SCAN_COUNT=200

usage() {
  cat <<'EOF'
Usage: monitor_campaign.sh [-i seconds] [-o output_file] [--db-query]

Monitors Redis health, DB readiness, CPU/RAM usage, and webhook buffer backlog.
Defaults: interval=5s, stdout only.

Env overrides:
  REDIS_URL / REDIS_HOST / REDIS_PORT / REDIS_PASSWORD
  DATABASE_URL / PGHOST / PGPORT / PGUSER / PGPASSWORD / PGDATABASE
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--interval)
      INTERVAL="$2"
      shift 2
      ;;
    -o|--output)
      OUT_FILE="$2"
      shift 2
      ;;
    --db-query)
      DB_QUERY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown arg: $1"
      usage
      exit 1
      ;;
  esac
done

log_line() {
  if [[ -n "$OUT_FILE" ]]; then
    printf "%s\n" "$1" | tee -a "$OUT_FILE"
  else
    printf "%s\n" "$1"
  fi
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

parse_redis_config() {
  local cfg="$ROOT_DIR/config/runtime.exs"
  if [[ -f "$cfg" ]]; then
    REDIS_HOST="${REDIS_HOST:-$(awk '
      /config :titan_flow, :redix/ {in_block=1; next}
      in_block && /host:/ {gsub(/[",]/,"",$2); print $2; exit}
      in_block && /^[^ ]/ {in_block=0}
    ' "$cfg")}"
    REDIS_PORT="${REDIS_PORT:-$(awk '
      /config :titan_flow, :redix/ {in_block=1; next}
      in_block && /port:/ {gsub(/[,]/,"",$2); print $2; exit}
      in_block && /^[^ ]/ {in_block=0}
    ' "$cfg")}"
    REDIS_PASSWORD="${REDIS_PASSWORD:-$(awk '
      /config :titan_flow, :redix/ {in_block=1; next}
      in_block && /password:/ {gsub(/[",]/,"",$2); print $2; exit}
      in_block && /^[^ ]/ {in_block=0}
    ' "$cfg")}"
  fi
}

redis_cmd() {
  if [[ -n "${REDIS_URL:-}" ]]; then
    redis-cli -u "$REDIS_URL" "$@"
    return
  fi

  parse_redis_config
  local host="${REDIS_HOST:-127.0.0.1}"
  local port="${REDIS_PORT:-6379}"
  local auth_opts=()
  if [[ -n "${REDIS_PASSWORD:-}" ]]; then
    auth_opts=(-a "$REDIS_PASSWORD")
  fi
  redis-cli -h "$host" -p "$port" "${auth_opts[@]}" "$@"
}

db_ready() {
  if ! command -v pg_isready >/dev/null 2>&1; then
    echo "skip(no pg_isready)"
    return
  fi

  if [[ -n "${DATABASE_URL:-}" ]]; then
    pg_isready -d "$DATABASE_URL" >/dev/null 2>&1 && echo "ok" || echo "down"
    return
  fi

  if [[ -n "${PGHOST:-}" ]]; then
    pg_isready >/dev/null 2>&1 && echo "ok" || echo "down"
    return
  fi

  echo "skip(no db env)"
}

db_query() {
  if [[ "$DB_QUERY" -ne 1 ]]; then
    echo "skip"
    return
  fi

  if ! command -v psql >/dev/null 2>&1; then
    echo "skip(no psql)"
    return
  fi

  if [[ -n "${DATABASE_URL:-}" ]]; then
    psql "$DATABASE_URL" -c "select 1" >/dev/null 2>&1 && echo "ok" || echo "err"
    return
  fi

  if [[ -n "${PGHOST:-}" ]]; then
    psql -c "select 1" >/dev/null 2>&1 && echo "ok" || echo "err"
    return
  fi

  echo "skip(no db env)"
}

read_cpu() {
  read -r _ user nice system idle iowait irq softirq steal _ _ < /proc/stat
  local idle_total=$((idle + iowait))
  local total=$((user + nice + system + idle + iowait + irq + softirq + steal))
  echo "${total} ${idle_total}"
}

cpu_usage() {
  local prev_total="$1"
  local prev_idle="$2"
  local curr_total="$3"
  local curr_idle="$4"
  local diff_total=$((curr_total - prev_total))
  local diff_idle=$((curr_idle - prev_idle))
  if [[ "$diff_total" -le 0 ]]; then
    echo "0.0"
    return
  fi
  awk -v total="$diff_total" -v idle="$diff_idle" 'BEGIN {printf "%.1f", (1 - idle/total) * 100}'
}

mem_usage() {
  local mem_total mem_avail
  mem_total=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
  mem_avail=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
  local used=$((mem_total - mem_avail))
  awk -v used="$used" -v total="$mem_total" 'BEGIN {printf "%.1f", used/1024/1024}'
}

beam_stats() {
  if ! command -v ps >/dev/null 2>&1; then
    echo "beam_cpu=na beam_mem=na"
    return
  fi

  local beam_cpu beam_rss
  beam_cpu=$(ps -C beam.smp -o %cpu= 2>/dev/null | awk '{sum+=$1} END {printf "%.1f", sum+0}')
  beam_rss=$(ps -C beam.smp -o rss= 2>/dev/null | awk '{sum+=$1} END {printf "%.0f", sum/1024}')
  if [[ -z "$beam_cpu" ]]; then
    beam_cpu="0.0"
  fi
  if [[ -z "$beam_rss" ]]; then
    beam_rss="0"
  fi
  echo "beam_cpu=${beam_cpu}% beam_mem=${beam_rss}MB"
}

redis_health() {
  if ! command -v redis-cli >/dev/null 2>&1; then
    echo "redis=skip(no redis-cli)"
    return
  fi

  local ping="err"
  if redis_cmd PING >/dev/null 2>&1; then
    ping="ok"
  fi

  local info_stats info_mem clients ops mem
  info_stats="$(redis_cmd INFO stats 2>/dev/null || true)"
  info_mem="$(redis_cmd INFO memory 2>/dev/null || true)"
  clients="$(awk -F: '/connected_clients/ {print $2}' <<<"$info_stats" | tr -d '\r')"
  ops="$(awk -F: '/instantaneous_ops_per_sec/ {print $2}' <<<"$info_stats" | tr -d '\r')"
  mem="$(awk -F: '/used_memory_human/ {print $2}' <<<"$info_mem" | tr -d '\r')"

  local webhook_buf log_buf history_buf
  webhook_buf="$(redis_cmd LLEN buffer:webhook_updates 2>/dev/null || echo "na")"
  log_buf="$(redis_cmd LLEN buffer:message_logs 2>/dev/null || echo "na")"
  history_buf="$(redis_cmd LLEN buffer:contact_history 2>/dev/null || echo "na")"
  queue_info="$(redis_queue_depth)"

  echo "redis=${ping} clients=${clients:-na} ops=${ops:-na} mem=${mem:-na} webhook_buf=${webhook_buf} log_buf=${log_buf} history_buf=${history_buf} ${queue_info}"
}

redis_queue_depth() {
  if ! command -v redis-cli >/dev/null 2>&1; then
    echo "queues=skip(no redis-cli)"
    return
  fi

  local cursor=0
  local total=0
  local keys_checked=0
  local truncated=0

  while true; do
    local scan_out new_cursor
    scan_out="$(redis_cmd --raw SCAN "$cursor" MATCH "queue:sending:*" COUNT "$QUEUE_SCAN_COUNT" 2>/dev/null || true)"
    if [[ -z "$scan_out" ]]; then
      break
    fi

    new_cursor="$(awk 'NR==1 {print; exit}' <<<"$scan_out")"
    if [[ -z "$new_cursor" ]]; then
      break
    fi
    cursor="$new_cursor"

    while IFS= read -r key; do
      [[ -z "$key" ]] && continue
      total=$((total + $(redis_cmd LLEN "$key" 2>/dev/null || echo 0)))
      keys_checked=$((keys_checked + 1))
      if [[ "$keys_checked" -ge "$QUEUE_KEY_LIMIT" ]]; then
        truncated=1
        break
      fi
    done < <(awk 'NR>1 {print}' <<<"$scan_out")

    if [[ "$cursor" == "0" || "$truncated" -eq 1 ]]; then
      break
    fi
  done

  if [[ "$truncated" -eq 1 ]]; then
    echo "queues_total~${total} queues_keys_checked=${keys_checked}"
  else
    echo "queues_total=${total} queues_keys_checked=${keys_checked}"
  fi
}

prev_total=0
prev_idle=0
read -r prev_total prev_idle < <(read_cpu)

log_line "# monitor_campaign.sh interval=${INTERVAL}s db_query=${DB_QUERY}"

while true; do
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  read -r curr_total curr_idle < <(read_cpu)
  cpu="$(cpu_usage "$prev_total" "$prev_idle" "$curr_total" "$curr_idle")"
  prev_total="$curr_total"
  prev_idle="$curr_idle"

  mem_used_gb="$(mem_usage)"
  beam_info="$(beam_stats)"
  redis_info="$(redis_health)"
  db_info="$(db_ready)"
  db_q="$(db_query)"

  log_line "[$ts] cpu=${cpu}% mem_used=${mem_used_gb}GB ${beam_info} db=${db_info} db_query=${db_q} ${redis_info}"
  sleep "$INTERVAL"
done
