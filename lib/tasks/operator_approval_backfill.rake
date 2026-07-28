# frozen_string_literal: true

namespace :tasks do
  # One-time correction for the rows the OLD one-shot settle left behind.
  #
  # Until 2026-07-27 the waiting → none settle fired only on the single save that
  # moved a task into `submitted`, so anything that rewrote devops afterwards
  # (a wholesale `bin/task update` echo, a post-submit approval flag) restored
  # "waiting" and nothing ever cleared it again — the request rode to `shipped`
  # and kept flashing WAITING APPROVAL on a finished card.
  # Task#settle_operator_approval_past_submit now holds the invariant on EVERY
  # save, but a row nobody saves again never gets it. This is that sweep.
  #
  # Idempotent and safe to re-run: it only ever moves "waiting" → "none", only on
  # tasks past the seam, and update_column skips callbacks + touches nothing else
  # (no broadcasts, no timestamps, no stage churn on historical rows).
  desc "Settle stale WAITING operator-approval requests on tasks past the submitted seam"
  task settle_stale_operator_approvals: :environment do
    settled = Task.settle_stale_operator_approvals!

    puts "settled #{settled.size} stale waiting-approval request(s)"
    settled.each { |slug| puts "  #{slug}" }
  end
end
