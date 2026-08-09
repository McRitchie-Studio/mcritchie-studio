# frozen_string_literal: true

namespace :ci do
  # Thin wrapper — the logic and its tests live in Ci::RunReconciler, because a
  # heal nobody can test is a heal nobody should trust.
  #
  # OPERATOR-RUN ONE-TIME HEAL, not a post_deploy_cmd: the ingest fix is
  # forward-only, so run this once by hand after it ships to repair rows already
  # stored against the wrong attempt.
  #
  #   DAYS=30   how far back to look (bounds the API calls; note the oldest row
  #             is 2026-07-16, so any bound above ~30 means "the whole table")
  #   DRY_RUN=1 report what would change without writing
  desc "Reconcile ingested CI conclusions against the GitHub Actions API (heals re-run rows)"
  task reconcile_workflow_runs: :environment do
    days = ENV.fetch("DAYS", "30").to_i
    dry_run = ENV["DRY_RUN"].present?
    result = Ci::RunReconciler.call(days: days, dry_run: dry_run, io: $stdout)

    puts("ci:reconcile_workflow_runs#{' (DRY RUN)' if dry_run}: " \
         "#{result.checked} checked, #{result.corrected} corrected, " \
         "#{result.unreadable} unreadable (last #{days}d)")
  end
end
