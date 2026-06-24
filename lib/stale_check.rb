# frozen_string_literal: true

# The stale-task decision: is a task's work already on origin/main (shipped
# out-of-band) while the task itself still lags behind? It happens — a fix gets
# cut straight to main while its task sits at `designed` (e.g. the
# fix-dor-check-release-cut-base case), and the board silently drifts from reality.
#
# This module is the PURE half of `bin/task stale`: branch resolution + the
# status decision. It performs NO git and NO network — the CLI injects the two
# git facts (does the remote branch exist? is it an ancestor of origin/main?), so
# the decision is unit-testable without a repo, exactly like ClaimLease keeps the
# claim math out of the process tree.
module StaleCheck
  # A task in one of these stages is, by definition, NOT stale — its work has
  # already reached (or left) the integration line, so "already on main" is
  # expected, not a drift to flag.
  TERMINAL_STAGES = %w[shipped archived].freeze

  # The branch a task's work lives on: an explicit devops.branch, else the
  # conventional feat/<slug>.
  def self.branch_for(task)
    branch = (task.dig("metadata", "devops") || {})["branch"].to_s.strip
    branch.empty? ? "feat/#{task["slug"]}" : branch
  end

  # The disposition of a task given the two git facts the caller resolved:
  #   :terminal    — already shipped/archived → not stale by definition
  #   :no_branch   — origin/<branch> does not exist → nothing to compare (skip)
  #   :on_main     — origin/<branch> IS an ancestor of origin/main → STALE
  #   :not_merged  — branch exists but carries un-merged commits → active
  #
  # branch_exists / on_main are the booleans from `git rev-parse` and
  # `git merge-base --is-ancestor`. Order matters: terminal short-circuits before
  # the branch facts, and a missing branch short-circuits before on_main, so a git
  # error that leaves on_main false never false-flags an absent branch as stale.
  def self.status(task, branch_exists:, on_main:)
    return :terminal if TERMINAL_STAGES.include?(task["stage"])
    return :no_branch unless branch_exists

    on_main ? :on_main : :not_merged
  end
end
