#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ -f "$ROOT_DIR/.env.production" ] && [ -z "${DATABASE_HOST:-}" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$ROOT_DIR/.env.production"
  set +a
fi

WINDOW_MINUTES="${OPS_WINDOW_MINUTES:-15}"
if ! [[ "$WINDOW_MINUTES" =~ ^[0-9]+$ ]]; then
  WINDOW_MINUTES=15
fi

REDIS_HOST="${REDIS_HOST:-127.0.0.1}"
REDIS_PORT="${REDIS_PORT:-6379}"

if [ -n "${REDIS_PASSWORD:-}" ]; then
  export REDISCLI_AUTH="$REDIS_PASSWORD"
fi

webhook_buf=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" LLEN buffer:webhook_updates 2>/dev/null || echo 0)
log_buf=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" LLEN buffer:message_logs 2>/dev/null || echo 0)
contact_buf=$(redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" LLEN buffer:contact_history 2>/dev/null || echo 0)

PGHOST="${DATABASE_HOST:-127.0.0.1}"
PGPORT="${DATABASE_PORT:-6543}"
PGUSER="${DATABASE_USERNAME:-postgres.postgres}"
PGDATABASE="${DATABASE_NAME:-titan_flow}"
export PGPASSWORD="${DATABASE_PASSWORD:-}"

SQL="WITH inbound AS (\
  SELECT id, conversation_id, inserted_at\
  FROM messages\
  WHERE direction = 'inbound'\
    AND inserted_at >= now() - interval '${WINDOW_MINUTES} minutes'\
),\
first_reply AS (\
  SELECT i.id AS inbound_id,\
         i.inserted_at AS inbound_at,\
         o.inserted_at AS reply_at,\
         o.is_ai_generated\
  FROM inbound i\
  LEFT JOIN LATERAL (\
     SELECT inserted_at, is_ai_generated\
     FROM messages m2\
     WHERE m2.conversation_id = i.conversation_id\
       AND m2.direction = 'outbound'\
       AND m2.inserted_at >= i.inserted_at\
     ORDER BY m2.inserted_at\
     LIMIT 1\
  ) o ON true\
  WHERE o.inserted_at IS NOT NULL\
)\
SELECT\
  is_ai_generated,\
  count(*) AS replies,\
  round(extract(epoch from percentile_cont(0.5) within group (order by reply_at - inbound_at))) AS p50_s,\
  round(extract(epoch from percentile_cont(0.95) within group (order by reply_at - inbound_at))) AS p95_s\
FROM first_reply\
GROUP BY is_ai_generated;"

sql_result=$(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -At -F ',' -c "$SQL" 2>/dev/null || true)

ai_replies=0
ai_p50="NA"
ai_p95="NA"
faq_replies=0
faq_p50="NA"
faq_p95="NA"

while IFS=',' read -r is_ai replies p50 p95; do
  if [ "$is_ai" = "t" ]; then
    ai_replies="$replies"
    ai_p50="$p50"
    ai_p95="$p95"
  elif [ "$is_ai" = "f" ]; then
    faq_replies="$replies"
    faq_p50="$p50"
    faq_p95="$p95"
  fi
done <<< "$sql_result"

printf "WebhookBuf=%s LogBuf=%s ContactBuf=%s | AI replies=%s p50=%ss p95=%ss | FAQ replies=%s p50=%ss p95=%ss | Window=%sm\n" \
  "$webhook_buf" "$log_buf" "$contact_buf" \
  "$ai_replies" "$ai_p50" "$ai_p95" \
  "$faq_replies" "$faq_p50" "$faq_p95" \
  "$WINDOW_MINUTES"
