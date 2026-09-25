# Fills one task's blank `devops.pr_url` with the PR whose head is its branch
# (Task#cache_derived_pr_url!). Enqueued by tasks#show, which serves the recorded
# column and never waits on GitHub itself (task-show-never-waits-github).
#
# Best-effort, like TaskMergedRungRefreshJob: the column is a cache that bin/ship
# also writes, so a failed fill is logged and swallowed, and the next show heals it.
class TaskPrUrlCacheJob < ApplicationJob
  def perform(slug, derivation: nil)
    task = Task.find_by(slug: slug.to_s)
    return unless task

    task.cache_derived_pr_url!(derivation: derivation || Github::TaskDerivation.shared)
  rescue StandardError => e
    log = ErrorLog.capture!(e)
    log.target = task if task
    log.target_name = slug.to_s
    log.save!
  end
end
