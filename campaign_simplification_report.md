# Campaign Sending Simplification Report

## Scope
Focused on campaign sending, template/number fallback, webhook handling, and throughput/DB load controls.

## Findings
Critical: Webhook-driven template switching writes an active template to Redis, but the send path never reads it and the cache is never initialized at campaign start, so late-binding fallback does not actually change what gets sent. `lib/titan_flow/campaigns/quality_monitor.ex`, `lib/titan_flow/campaigns/cache.ex`, `lib/titan_flow/campaigns/pipeline.ex`, `lib/titan_flow/campaigns/orchestrator.ex`
High: Phone fallback/rotation uses mismatched identifiers (Redis stores phone_number_id while retry selection checks DB phone_ids), so exhausted phones are not reliably excluded and retries can route back to the same failed number. `lib/titan_flow/campaigns/pipeline.ex`, `lib/titan_flow/campaigns/message_tracking.ex`, `lib/titan_flow/campaigns/retry_manager.ex`
High: Retry requeue payloads drop all original template variables/media, so number fallback can resend invalid or incomplete templates. `lib/titan_flow/campaigns/retry_manager.ex`
Medium: Template fallback order is nondeterministic because template IDs are stored from MapSet to list and Enum.uniq preserves first-seen order, which can vary by run/selection. `lib/titan_flow_web/live/campaign_live/new.ex`, `lib/titan_flow_web/live/campaign_live/resume.ex`
Medium: Template fallback on API errors depends on parsing the failure reason string; extracted Meta error codes are not used to decide fallback, so 132xxx errors may not reliably trigger template switching. `lib/titan_flow/campaigns/pipeline.ex`
Medium: Webhook POSTs are accepted without signature verification, and template paused cache entries expire after 24h even if the template remains paused, so spoofed or stale states can affect fallback. `lib/titan_flow_web/controllers/webhook_controller.ex`, `lib/titan_flow/campaigns/cache.ex`

## Template Fallback Today
- Campaign creation picks primary_template_id as the first selected template and fallback_template_id as the next; per-phone template lists come from senders_config. `lib/titan_flow_web/live/campaign_live/new.ex`, `lib/titan_flow_web/live/campaign_live/resume.ex`
- The pipeline tries templates sequentially per message and skips templates marked paused in Redis; template failures are tracked per phone in Redis. `lib/titan_flow/campaigns/pipeline.ex`, `lib/titan_flow/campaigns/cache.ex`
- Webhooks update template status/category, invalidate ETS cache, and mark templates paused; this influences the pipeline only via the paused check, not via active-template switching. `lib/titan_flow_web/controllers/webhook_controller.ex`, `lib/titan_flow/campaigns/pipeline.ex`
- MessageTracking can switch the DB primary template after a failure threshold and enqueue retries, but the pipeline does not read primary_template_id, so this does not change the live send choice. `lib/titan_flow/campaigns/message_tracking.ex`, `lib/titan_flow/campaigns/pipeline.ex`
- The fallback list and active-template cache helpers exist but are not wired into the send path. `lib/titan_flow/campaigns/cache.ex`

## Number Fallback Today
- A phone is marked exhausted when all templates fail or a critical 131042 error is detected; if all phones are exhausted the campaign is paused. `lib/titan_flow/campaigns/pipeline.ex`
- Error-code thresholds (131042/131048/130429) trigger phone rotation and retry failed workflows via RetryManager. `lib/titan_flow/campaigns/message_tracking.ex`, `lib/titan_flow/campaigns/retry_manager.ex`
- RetryManager requeues failed messages from the last hour to another phone queue if it finds an active phone. `lib/titan_flow/campaigns/retry_manager.ex`
- BufferManager uses strict modulo distribution and does not rebalance unsent contacts when a phone fails, so only already-failed messages are retried, not unsent ones. `lib/titan_flow/campaigns/buffer_manager.ex`
- RateLimiter handles 429 backoff locally; those errors do not currently participate in the phone-rotation threshold logic. `lib/titan_flow/whatsapp/rate_limiter.ex`, `lib/titan_flow/campaigns/message_tracking.ex`

## Webhook Handling
- `/api/webhooks/whatsapp` and `/api/webhooks` return 200 immediately and process in a supervised task, which is good for Meta response timing. `lib/titan_flow_web/router.ex`, `lib/titan_flow_web/controllers/webhook_controller.ex`
- Template status/category webhooks update DB, invalidate TemplateCache, mark paused in Redis, and call QualityMonitor; only the paused flag affects actual sending. `lib/titan_flow_web/controllers/webhook_controller.ex`, `lib/titan_flow/campaigns/quality_monitor.ex`
- Message status webhooks update MessageLogs; if the log is not found after 2 retries, updates are dropped, which can weaken fallback triggers based on failed statuses. `lib/titan_flow/campaigns/message_tracking.ex`
- Incoming messages are deduped, conversation-upserted, and replies are recorded for campaign stats. `lib/titan_flow_web/controllers/webhook_controller.ex`

## Throughput and DB Load Controls
- BufferManager keeps per-phone queues under 20k and refills in 10k batches every 5s using indexed joins, reducing DB pressure. `lib/titan_flow/campaigns/buffer_manager.ex`, `priv/repo/migrations/20251216093333_add_contact_campaign_index_to_message_logs.exs`
- Broadway pipelines run 10 processors per phone, Redis producer batches 200 items, and Finch is sized for 500 concurrent connections. `lib/titan_flow/campaigns/pipeline.ex`, `lib/titan_flow/application.ex`
- RateLimiter enforces per-phone MPS via Hammer and adapts using Meta headers; AutoScaler adjusts MPS by queue depth but the DB-throttle flag is not wired. `lib/titan_flow/whatsapp/rate_limiter.ex`, `lib/titan_flow/campaigns/auto_scaler.ex`
- LogBatcher and Redis counters batch writes and reduce hot DB updates; CounterSync persists counters periodically. `lib/titan_flow/campaigns/log_batcher.ex`, `lib/titan_flow/campaigns/counter_sync.ex`
- ETS caches for templates and phone IDs reduce DB reads; pipeline also builds a local template cache at startup. `lib/titan_flow/templates/template_cache.ex`, `lib/titan_flow/whatsapp/phone_cache.ex`, `lib/titan_flow/campaigns/pipeline.ex`

## Simplification Guidance (remove to speed, keep fallback)
- Stop persisting delivered/read webhook updates to the database; keep only failure handling and an optional sent counter. Fallback is driven by send-time errors and does not require delivered/read writes.
- Disable contact_history upserts if strict cross-campaign dedup is not required during high-throughput sending. Fallback remains intact.
- Disable MetricsReporter and AutoScaler if you prefer simplicity; they add periodic Redis/DB work and do not drive fallback.
- Reduce or disable periodic TemplateCache refreshes; refresh on Meta sync/webhooks only. This cuts steady DB reads without affecting fallback.
- Disable CounterSync if you accept Redis as the source of truth during runs and only persist stats at completion.

## Loopholes and Solutions
Each solution (a/b/c) is a distinct option. Pick one per loophole. A recommendation is provided for each.

Loophole 1.
Active-template cache is not read by the pipeline and not set at campaign start, so webhook-driven template switching does not change sends.

solution a
Option: Wire active-template cache into the pipeline and set it at campaign start.
Pros
- Webhook-driven fallback actually changes sends
- Clear source of truth for the current template
Cons
- Extra Redis read or cache check per message

solution b
Option: Remove active-template cache and rely only on per-message sequential fallback.
Pros
- Simpler mental model and fewer Redis keys
- No cache coherence issues
Cons
- Slower reaction to template-wide pauses if per-message fallback is exhausted

solution c
Option: Use active-template cache only when a template is paused; otherwise use per-message fallback.
Pros
- Minimal Redis lookups most of the time
- Fast global switch when needed
Cons
- More complex conditional logic

Recommendation: solution a. It is the only option that fully honors webhook-driven template fallback as designed.

Loophole 2.
Phone rotation uses inconsistent identifiers, so exhausted phones are not reliably excluded.

solution a
Option: Normalize everything to phone_number_id in Redis and campaigns.
Pros
- Reliable number fallback and retry routing
- Easier reasoning across components
Cons
- Migration effort and data consistency work

solution b
Option: Store a canonical mapping and convert at all boundaries (DB id to phone_number_id).
Pros
- Lower migration risk
- Backward compatible
Cons
- Extra lookup steps and mapping drift risk

solution c
Option: Stop cross-phone retries and keep failures on the same phone only.
Pros
- Simplifies routing logic
- No identifier mismatch issues
Cons
- Lower recovery rate for exhausted phones

Recommendation: solution a. It removes an entire class of retry/fallback bugs.

Loophole 3.
Retry payloads drop variables/media, causing invalid retries and wasted API calls.

solution a
Option: Store full send payload in Redis with a short TTL for retry use.
Pros
- Retries are correct and complete
- Avoids extra DB reads
Cons
- Extra Redis memory and PII handling considerations

solution b
Option: Reconstruct payload at retry time from contact data.
Pros
- No extra Redis memory
- Centralized payload construction
Cons
- Additional DB reads during retry spikes

solution c
Option: Disable automatic retries and allow manual retry only.
Pros
- Simplest runtime behavior
- No wasted retries with bad payloads
Cons
- Slower recovery and more manual work

Recommendation: solution a for speed; solution b if you prefer lower Redis usage.

Loophole 4.
Template order is nondeterministic, so primary and fallback can vary between runs.

solution a
Option: Persist ordered template lists per phone and enforce order in UI.
Pros
- Deterministic fallback behavior
- Clear operator control
Cons
- Additional UI and validation work

solution b
Option: Sort template IDs by name or ID before saving.
Pros
- Deterministic with minimal UI change
- Simple to reason about
Cons
- Order may not reflect business priority

solution c
Option: Keep current behavior but log final order and show it in the UI.
Pros
- No changes to selection mechanics
- Transparent debugging
Cons
- Still nondeterministic if selection order changes

Recommendation: solution a if you want explicit control; solution b if you want minimal changes.

Loophole 5.
Template fallback on API errors relies on parsing failure strings instead of error codes.

solution a
Option: Drive fallback from extracted Meta error codes (132xxx).
Pros
- Reliable template switching logic
- Less brittle than string parsing
Cons
- Requires careful error code mapping

solution b
Option: Add explicit mapping table for template errors and keep string parsing as a fallback.
Pros
- Backward compatible and robust
Cons
- More maintenance overhead

solution c
Option: Remove template-error fallback on API errors and rely only on webhooks.
Pros
- Simpler logic
- Avoids misclassification
Cons
- Slower reaction to template failures

Recommendation: solution a. It is most reliable and fastest to react.

Loophole 6.
Webhook signature not verified; paused cache expires after 24h even if template remains paused.

solution a
Option: Verify signatures and make paused status persistent until an approved event clears it.
Pros
- Strong security and correct pause behavior
- Prevents stale resume
Cons
- Slight compute cost and secret management

solution b
Option: Keep TTL but extend it (e.g., 7 days) and verify signatures.
Pros
- Lower complexity than full persistence
- Improved security
Cons
- Stale pause may still expire

solution c
Option: Keep current TTL and accept risk.
Pros
- No changes
Cons
- Spoofing risk and incorrect fallback on stale cache

Recommendation: solution a for correctness and security.

Loophole 7.
Webhook status updates (sent/delivered/read) create high DB write volume and read retries, but do not affect fallback.

solution a
Option: Persist only failed statuses and optionally a sent counter; ignore delivered/read.
Pros
- Large DB write reduction
- Keeps fallback signals intact
Cons
- Reduced analytics and lifecycle detail

solution b
Option: Buffer status updates in Redis and batch-write later.
Pros
- Preserves analytics with fewer synchronous writes
Cons
- More operational complexity and Redis memory usage

solution c
Option: Keep current behavior but reduce retry attempts for missing logs.
Pros
- Less extra DB reads during webhook bursts
Cons
- Still high write volume

Recommendation: solution a if speed is the priority; solution b if analytics are required.

Loophole 8.
contact_history upserts run for every send, adding steady DB write load with no impact on fallback.

solution a
Option: Remove contact_history writes during campaign sends.
Pros
- Immediate DB write reduction
- No impact on fallback
Cons
- Loses cross-campaign dedup history

solution b
Option: Replace contact_history with Redis TTL dedup keys.
Pros
- Fast, no DB writes at send time
- Dedup still works within TTL window
Cons
- Redis memory usage and loss on restart

solution c
Option: Run dedup once at campaign start only.
Pros
- Keeps dedup while avoiding per-message writes
Cons
- Longer pre-send step and higher batch load

Recommendation: solution b for speed with dedup; solution a for maximum throughput if dedup is optional.

Loophole 9.
MetricsReporter and AutoScaler add periodic Redis scans and do not drive fallback.

solution a
Option: Disable MetricsReporter.
Pros
- Fewer Redis calls and log overhead
Cons
- Reduced visibility

solution b
Option: Disable AutoScaler and rely on RateLimiter header-based adaptation.
Pros
- Simpler runtime behavior
Cons
- Less dynamic queue draining

solution c
Option: Keep them but avoid Redis KEYS scans and reduce frequency.
Pros
- Keeps observability with less overhead
Cons
- Still adds complexity

Recommendation: solution b if simplicity is the goal; solution c if you need metrics.

Loophole 10.
CounterSync writes stats to DB every 5 minutes during runs, adding non-critical write load.

solution a
Option: Disable CounterSync during active campaigns.
Pros
- Fewer DB writes under load
Cons
- Loss of near-real-time persistence if Redis restarts

solution b
Option: Sync only on campaign completion or pause.
Pros
- Keeps persistence while minimizing runtime writes
Cons
- Less real-time accuracy

solution c
Option: Increase sync interval substantially.
Pros
- Simple way to reduce DB writes
Cons
- Slower recovery if Redis state is lost

Recommendation: solution b to balance durability and throughput.

## Open Questions / Assumptions
- Should fallback be active-template per campaign (late-binding) or per-message template tries, or both?
- Which identifier is canonical for phone rotation: DB phone_ids or Meta phone_number_id?
- Is template ordering intended to be user-controlled, or is any order acceptable?
- Are retries expected to preserve full template variables/media, or is a minimal retry acceptable?
