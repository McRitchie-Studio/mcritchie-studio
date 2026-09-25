# The three task facts the board DERIVES from GitHub rather than being told
# (epic devops-v3, piece 4a): the merged rung, the PR url, and the author set.
#
# ONE RELEASE OF OVERLAP. The hand-written stamps (`merged`, `devops.pr_url`,
# `devops.built_by` / `builders`) stay, and every reader here falls back to them:
#
#   * #merged_rung      — the derived rung when GitHub places the merge commit on
#                         a rung; the stamp when it cannot (unreadable, not merged
#                         yet, or derivation switched off). So `bin/task merged`
#                         still works as a manual override for a PR GitHub cannot
#                         place, and a failed read never erases a real stamp.
#   * #pr_url_or_derived — the recorded url, else the PR whose head is the task
#                         branch.
#   * #derived_authors  — souls on the PR's commits; the SELECTOR unions them with
#                         the stamps, so a derived set can only ADD exclusions.
#
# Every read is PURE: nothing here writes. #refresh_merged_rung! is the one writer,
# and it is explicit, so a read-only release snippet (sweep_detect_ruby previews
# under --dry-run) stays read-only.
#
# NOBODY HAND-STAMPS NOW (piece 4c-i). The `merged` column is a CACHE the board
# refreshes itself, from three places: TaskMergedRungRefreshJob, enqueued when a
# task lands on `reviewed` (review's merge has just happened) and when GitHub
# delivers a merged `pull_request` event; and the release record steps, which
# refresh advance-only after their own write. `bin/task merged` stays as a manual
# override for a PR GitHub cannot place, and says it is no longer needed.
#
# SWITCH. `config.x.derive_from_github = false` (set in test) disables the DEFAULT
# derivation, so a test that never asked for GitHub never reaches it. A caller that
# passes `derivation:` explicitly is always served.
module TaskDerivedFacts
  extend ActiveSupport::Concern

  included do
    # Review merges the PR, then moves the task `reviewed`. The move is the board's
    # cue that a merge just happened, so it refreshes the cache itself instead of
    # asking review to stamp it. Only when derivation is on: with it off (test)
    # the refresh could only ever read the stamp back, so there is nothing to do.
    after_commit :enqueue_merged_rung_refresh, on: :update,
                                               if: -> { saved_change_to_stage? && stage == "reviewed" && TaskDerivedFacts.enabled? }
  end

  def self.enabled?
    Rails.configuration.x.derive_from_github != false
  end

  # The default derivation, or nil when switched off: the per-process shared one
  # (Github::TaskDerivation.shared), so every task in a sweep shares its caches and
  # its failure breaker. Memoized per task instance.
  def github_derivation
    return @github_derivation if defined?(@github_derivation)

    @github_derivation = TaskDerivedFacts.enabled? ? Github::TaskDerivation.shared : nil
  end

  # The rung the task's PR merge commit sits on — "main", "release", "accepted" —
  # or nil when GitHub places none. A multi-repo task is only as far along as its
  # least-advanced repo, so the LOWEST rung across its PRs wins, and any repo that
  # has not merged makes the whole answer nil. Raises
  # Github::TaskDerivation::Unreadable on a failed read.
  def derived_merged_rung(derivation: github_derivation)
    return nil unless derivation

    derived_memo(:merged_rung, derivation) do
      urls = derived_release_pr_urls(derivation: derivation).values
      next nil if urls.empty?

      rungs = urls.map { |url| derivation.merged_rung(url) }
      next nil if rungs.any?(&:nil?)

      rungs.max_by { |rung| Github::TaskDerivation::RUNGS.index(rung) }
    end
  end

  # The rung every release guard reads: derived when GitHub places the merge
  # commit, else the `merged` stamp (the manual override, and the fallback when
  # GitHub cannot be read).
  def merged_rung(derivation: github_derivation)
    derived_merged_rung(derivation: derivation).presence || merged
  rescue Github::TaskDerivation::Unreadable => e
    Rails.logger.warn("[task-derivation] #{slug}: merged rung unreadable, using the stamp: #{e.message}")
    merged
  end

  # Writes the derived rung into the `merged` column when they differ — the column
  # is now a CACHE of #merged_rung. Returns the rung. Never clears a stamp: a nil
  # derivation leaves the column alone.
  #
  # `advance_only: true` is for a caller that has just written the column from a
  # fact it performed itself (the release record steps): the refresh may carry the
  # column UP the ladder (a straggler GitHub already places on `main`) but never
  # down, because a derivation read moments after a promote can lag the promote.
  def refresh_merged_rung!(derivation: github_derivation, advance_only: false)
    rung = merged_rung(derivation: derivation)
    return rung if rung.blank? || rung == merged
    return merged if advance_only && !TaskDerivedFacts.higher_rung?(rung, merged)

    update!(merged: rung)
    rung
  end

  # True when `rung` sits above `than` on accepted → release → main. Anything
  # beats a blank column.
  def self.higher_rung?(rung, than)
    return true if than.blank?

    Github::TaskDerivation::RUNGS.index(rung.to_s).to_i < Github::TaskDerivation::RUNGS.index(than.to_s).to_i
  end

  # The PR whose head is this task's branch, in its primary repo — or nil.
  def derived_pr_url(derivation: github_derivation, repo: release_repo)
    return nil unless derivation

    # Keyed on the branch and the abandoned list too: abandoning a PR or renaming
    # the branch must not be answered from the memo.
    derived_memo([:pr_url, repo.to_s, derived_head_branch, devops_abandoned_prs], derivation) do
      derivation.pr_url_for_branch(repo, derived_head_branch, exclude: devops_abandoned_prs)
    end
  end

  def pr_url_or_derived(derivation: github_derivation)
    devops_url("pr").presence || derived_pr_url(derivation: derivation)
  rescue Github::TaskDerivation::Unreadable => e
    Rails.logger.warn("[task-derivation] #{slug}: PR url unreadable: #{e.message}")
    nil
  end

  # Stages whose task can have a PR. A `designed` card has none yet, and an
  # archived one is done asking, so neither costs a GitHub read on a show.
  PR_CACHE_STAGES = %w[building submitted reviewed assembled shipped].freeze

  # Fills a BLANK `devops.pr_url` with the derived one and returns the task's PR
  # url — the self-healing read tasks#show runs (the same shape as its gates
  # projection). This is what lets bin/ship skip its `--pr-url` write: the board
  # finds the PR on the task branch and caches it, so every reader that still
  # keys on `devops.pr_url` (dor-check, the review gate, the CI meter) sees it.
  # Never overwrites a recorded url, and never raises: an unreadable GitHub
  # leaves the column as it was and answers with what is recorded.
  def cache_derived_pr_url!(derivation: github_derivation)
    recorded = devops_url("pr")
    return recorded if recorded.present? || !PR_CACHE_STAGES.include?(stage.to_s)

    url = derived_pr_url(derivation: derivation)
    return nil if url.blank?

    fresh = metadata.deep_dup
    (fresh["devops"] ||= {})["pr_url"] = url
    update!(metadata: fresh)
    url
  rescue Github::TaskDerivation::Unreadable, ActiveRecord::ActiveRecordError => e
    Rails.logger.warn("[task-derivation] #{slug}: PR url not cached: #{e.class}: #{e.message}")
    recorded
  end

  # #release_pr_urls plus a derived PR for every repo the task names that carries
  # no recorded url. Recorded urls always win; derivation only fills gaps. A repo
  # whose lookup fails stays a gap, so the multi-repo record check still refuses it.
  def derived_release_pr_urls(derivation: github_derivation)
    recorded = release_pr_urls
    return recorded unless derivation

    gaps = release_repos.reject { |repo| recorded.key?(repo) }
    gaps.each_with_object(recorded.dup) do |repo, map|
      url = derived_pr_url(derivation: derivation, repo: repo)
      map[repo] = url if url.present?
    rescue Github::TaskDerivation::Unreadable => e
      Rails.logger.warn("[task-derivation] #{slug}: PR lookup for #{repo} unreadable: #{e.message}")
    end
  end

  # The souls who authored the task's PR(s). Empty when there is no PR, derivation
  # is off, or the read fails — the stamps then stand alone, as they did before.
  def derived_authors(derivation: github_derivation)
    return [] unless derivation

    derived_memo(:authors, derivation) do
      derived_release_pr_urls(derivation: derivation).values.flat_map do |url|
        derivation.authors(url)
      rescue Github::TaskDerivation::Unreadable => e
        Rails.logger.warn("[task-derivation] #{slug}: authors unreadable for #{url}: #{e.message}")
        []
      end.uniq
    end
  end

  private

  def enqueue_merged_rung_refresh
    TaskMergedRungRefreshJob.perform_later(slug)
  rescue StandardError => e
    Rails.logger.warn("[task-derivation] #{slug}: merged refresh not enqueued: #{e.class}: #{e.message}")
  end

  # Per-instance memo keyed by the derivation, so one sweep row asks GitHub each
  # question once however many readers it runs. A raise (Unreadable) is NOT
  # memoized; the derivation's own breaker makes the retry free.
  def derived_memo(key, derivation)
    @derived_memo ||= {}
    memo_key = [key, derivation.object_id]
    return @derived_memo[memo_key] if @derived_memo.key?(memo_key)

    @derived_memo[memo_key] = yield
  end

  # The branch the task's PR is headed from: the recorded branch, else the slug
  # trickle-down (`feat/<worktree_slug or slug>`).
  def derived_head_branch
    devops_field("branch").presence || "feat/#{devops_field('worktree_slug').presence || slug}"
  end
end
