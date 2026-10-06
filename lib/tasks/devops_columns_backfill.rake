# frozen_string_literal: true

namespace :tasks do
  # The post_deploy_cmd for the pr_url, branch, approval_status and session_id
  # columns: copies each devops key into its column (TaskDevopsColumnsBackfillJob).
  # Idempotent and safe to re-run. Exits non-zero when any row still diverges,
  # so a green post-deploy means every column matches its key. It calls #perform
  # directly, not perform_now: ApplicationJob's retry_on StandardError would turn
  # a failure into a queued retry and hide the job's own error from the deploy.
  desc "Copy devops pr_url, branch, approval_status and session_id into their task columns (idempotent)"
  task backfill_devops_columns: :environment do
    result = TaskDevopsColumnsBackfillJob.new.perform
    puts "tasks:backfill_devops_columns — updated #{result.updated} task(s); " \
         "#{result.divergent} still diverge(s) of #{Task.count}"
    abort "tasks:backfill_devops_columns — #{result.divergent} task(s) still diverge; re-run it" if result.divergent.positive?
  end
end
