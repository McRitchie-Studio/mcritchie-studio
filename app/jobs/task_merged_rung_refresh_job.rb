# Refreshes one task's `merged` column from GitHub (Task#refresh_merged_rung!), so
# no agent has to stamp it (devops-v3 piece 4c-i). Enqueued when a task lands on
# `reviewed` and when GitHub delivers a merged `pull_request` event.
#
# A FRESH derivation every run, never Github::TaskDerivation.shared: the shared one
# caches a PR read for up to a minute, and a read taken just before the merge would
# answer "not merged" to the very refresh the merge triggered.
#
# Best-effort: the column is a cache, and every reader derives live and falls back
# to it, so a failed refresh is logged and swallowed rather than retried into a
# storm. The next trigger (or the release sweep) heals it.
class TaskMergedRungRefreshJob < ApplicationJob
  def perform(slug, derivation: nil)
    task = Task.find_by(slug: slug.to_s)
    return unless task

    task.refresh_merged_rung!(derivation: derivation || Github::TaskDerivation.new)
  rescue StandardError => e
    log = ErrorLog.capture!(e)
    log.target = task if task
    log.target_name = slug.to_s
    log.save!
  end
end
