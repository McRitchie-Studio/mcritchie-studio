# Weekly staleness detector for docs/agents/shared/insights.md — the scheduled half
# of /tasks/insights-doc-never-regenerated. Registered in config/recurring.yml for
# production ONLY, because the board is the one environment holding both halves of
# the comparison: the live bank and the deployed copy of the tracked doc.
#
# THE RECEIPT IS AN ErrorLog ROW. A stale artefact was previously silent — nothing
# anywhere said the learning loop's own output had stopped tracking the loop. Now it
# surfaces where every other incident here surfaces (/admin/error_logs), carrying
# class, message, and backtrace, and outliving Heroku's log retention. A quiet run
# means the doc matched the bank.
#
# Backend discipline — best-effort, never crash: the body is rescued into ErrorLog
# and deliberately NOT re-raised, so ApplicationJob's `retry_on StandardError` cannot
# storm on a persistent read bug. The check is read-only and idempotent, so a
# swallowed run is covered by the next week's.
class InsightsDocFreshnessJob < ApplicationJob
  def perform
    # QA IS RAILS-PRODUCTION, so config/recurring.yml's `production:` block registers
    # this there too — but a QA app has only ONE half of the comparison. Its slug ships
    # the tracked doc carrying the BOARD's count while its own bank is empty, so every
    # run would read count_drift and file a weekly receipt about a doc that is CORRECT.
    # That is exactly the cry-wolf this detector's causal freshness bound exists to
    # avoid. Studio.qa_environment? reads QA_ENV, which the release conductor sets on
    # every QA app (config/qa_environments.yml).
    return if Studio.qa_environment?

    result = Insights::DocFreshness.check
    return if result.fresh?

    # Raised and caught here rather than constructed, so the receipt carries a real
    # backtrace pointing at this job instead of an empty one.
    begin
      raise Insights::DocFreshness::StaleDocError, result.message
    rescue Insights::DocFreshness::StaleDocError => e
      log = ErrorLog.capture!(e)
      log.target_name = result.status.to_s
      log.save!
    end
  rescue StandardError => e
    ErrorLog.capture!(e)
  end
end
