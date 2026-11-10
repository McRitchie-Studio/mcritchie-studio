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

namespace :ci do
  namespace :causes do
    # A SAME-SHA RED THEN GREEN IS A DEFECT WITH A CAUSE (Alex McRitchie, 2026-11-06).
    # The ingest files the cause cards live (GithubWorkflowRunIngestJob); this sweep
    # files them from CI HISTORY, for a repo or a window the webhook did not see.
    # Thin wrapper; the logic and its tests live in Ci::CauseSweep. Idempotent: an
    # occurrence already on a card is not folded twice.
    #
    #   REPO=McRitchie-Studio/mcritchie-studio   the repo to read (required)
    #   DAYS=14                                  how far back
    #   DRY_RUN=1                                list the flips, enqueue nothing
    desc "File CI cause cards for every same-SHA red then green in a repo's recent history"
    task sweep: :environment do
      repo = ENV.fetch("REPO")
      days = ENV.fetch("DAYS", "14").to_i
      dry_run = ENV["DRY_RUN"].present?
      flips = Ci::CauseSweep.call(repo: repo, days: days, dry_run: dry_run)
      flips.each { |f| puts "#{f[:workflow]} #{f[:sha][0, 8]} red #{f[:red][:run_id]}/#{f[:red][:attempt]} green #{f[:green][:run_id]}" }
      puts "ci:causes:sweep#{' (DRY RUN)' if dry_run}: #{flips.size} flip(s) in #{repo} over #{days}d#{dry_run ? '' : ', cards enqueued'}"
    end

    # ONE-TIME BOARD HEAL for cause cards filed before ci-cause-card-dedupe-census: merges
    # race twins of one cause (a base card and its `-2` holding the same red) and moves
    # past native crashes filed as web-server-boot (and their census) onto native-abort.
    # Thin wrapper; the logic and its tests live in Ci::CauseCleanup. Idempotent.
    #
    # OPERATOR-RUN, after it ships: DRY RUN BY DEFAULT. Read the plan, then apply.
    #   bin/rails ci:causes:cleanup            list what would change, write nothing
    #   APPLY=1 bin/rails ci:causes:cleanup    make the changes
    desc "Merge duplicate CI cause cards and move past native crashes onto native-abort (dry run unless APPLY=1)"
    task cleanup: :environment do
      apply = ENV["APPLY"] == "1"
      actions = Ci::CauseCleanup.call(apply: apply, io: $stdout)
      puts "ci:causes:cleanup#{' (DRY RUN; APPLY=1 to write)' unless apply}: #{actions.size} change(s)"
    end
  end
end
