# Mines resolved QA blocks into ActionGrade candidates (Insights::BlockMiner),
# off the request/handoff path. Enqueued when a handoff RESOLVES a block
# (Activity#mine_block_insights, scoped to that task) and runnable bare for a
# full backfill of the existing block ledger.
#
# Backend discipline — best-effort, never crash: the body is rescued into
# ErrorLog and we deliberately DON'T re-raise (so ApplicationJob's retry_on
# StandardError doesn't storm on a persistent scan bug). The miner is idempotent,
# so a swallowed run is safely re-tried by the next resolution or a backfill. The
# miner ALSO rescues per-block internally; this outer rescue is the backstop for a
# failure in the scan itself (e.g. the resolved-blocks query).
class BlockInsightMiningJob < ApplicationJob
  def perform(task_slug = nil)
    Insights::BlockMiner.mine!(task_slug: task_slug)
  rescue StandardError => e
    log = ErrorLog.capture!(e)
    log.target_name = task_slug
    log.save!
  end
end
