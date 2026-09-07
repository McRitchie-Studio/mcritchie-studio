# frozen_string_literal: true

# THE PULL REQUESTS A TASK ACTUALLY HAS — all of them, in a stable order.
#
# THE DEFECT THIS EXISTS TO CLOSE (/tasks/dor-check-reads-one-pr, found independently
# by two agents on 2026-09-07, hours apart). bin/dor-check read `devops.pr_url` —
# SINGULAR — for BOTH the PR file list and the CI verdict, while the plural
# `devops.pr_urls` register (written by `bin/task update --pr-url-for <repo>=<url>`)
# fed only the cert gate's repo list. On a two-repo task the gate therefore graded ONE
# repo's PR and printed a verdict that read as though it covered the task.
#
# Measured on /tasks/document-burn-entry-token (turf-vault PR 17 + turf-monster PR
# 575, both URLs recorded correctly): running the gate under
# DOR_CHECK_DIFF_ROOT=<turf-vault> and again under DOR_CHECK_DIFF_ROOT=<turf-monster>
# returned the IDENTICAL diff — turf-vault's three files — because PR files outrank
# the git tree and the tree loses. turf-monster's only changed file, docs/SOLANA.md,
# appeared in neither run.
#
# WHY THE OBVIOUS REMEDY DID NOT WORK. It was already known that the gate sees only
# the repos a task NAMES, and the standing fix for that is "fix the record". This is a
# rung below it: the record was RIGHT — both repos named, both PR URLs recorded — and
# the gate still read one. So no amount of record hygiene reaches it; the reader had
# to change.
#
# PURE, and deliberately so. Everything here is a function of the `devops` hash: no
# network, no git, no ENV. That is what lets the multi-repo properties be asserted
# without a live GitHub (test/lib/task_pr_set_test.rb) while bin/dor-check's own tests
# drive the whole gate through the injection seams.
module TaskPrSet
  # A GitHub pull-request URL, as the board records it.
  PR_URL = %r{github\.com/([^/]+)/([^/]+)/pull/(\d+)}

  # HOW BAD IS THIS CI VERDICT? Lower governs. The ordering is the merge gate's own
  # severity, not an opinion: a red PR is the #1 blocker class, a conflicted/ci-less
  # PR will never go green on its own, a closed/merged PR is not a live review target,
  # pending is "not yet", and the no-verdict family (unreadable/unverified/no_pr/none)
  # is "nobody knows" — which still outranks green, because on a multi-repo task an
  # unread repo is precisely the thing that must not be papered over by a sibling's
  # green.
  #
  # AN UNKNOWN STATE GOVERNS ABOVE ALL OF THEM (-1). This mirrors CiGate.verdict's
  # allow-list doctrine one level up: a state this table has never heard of must not
  # be able to lose to a sibling's green and vanish from the verdict. A deny-list here
  # would default the novel state to "harmless", which is exactly how :no_pr once
  # reached the review gate as a pass.
  CI_SEVERITY = {
    red: 0, conflicted: 1, ci_less: 2, closed: 3, merged: 4, pending: 5,
    unreadable: 6, unverified: 7, no_pr: 8, none: 9, green: 10
  }.freeze
  UNKNOWN_CI_SEVERITY = -1

  # The bare repo slug of a slug, an owner-qualified name, or a URL fragment.
  def self.bare_repo(value)
    value.to_s.strip.split("/").last.to_s.strip
  end

  # The repo a PR URL names, bare. "" when the URL is not a GitHub PR URL.
  def self.repo_from_url(url)
    url.to_s[PR_URL, 2].to_s.strip
  end

  # Is this string a GitHub pull-request URL this gate can read?
  def self.pr_url?(url)
    !url.to_s[PR_URL].nil?
  end

  # EVERY PR THE TASK RECORDS, as [{repo:, url:, recorded_as:, readable:}].
  #
  # ORDER IS PART OF THE CONTRACT: `devops.pr_url` first — it is what every existing
  # caller meant by "the PR", and keeping it first means a single-repo task resolves
  # byte-identically to the way it always has — then the `pr_urls` register by SORTED
  # key, so two runs of the same gate on the same record never disagree about which
  # repo they described.
  #
  # Deduped by URL, because the primary is normally ALSO registered under its own repo
  # key; counting it twice would read the same PR twice and report a task as
  # multi-repo when it is not.
  #
  # `readable:` is false for a URL that was RECORDED but is not a PR URL. That is not
  # the same fact as "no PR yet" (an empty pr_url, the builder's pre-PR run) and the
  # caller must not collapse them: somebody stating a PR the gate cannot parse is a
  # repo whose verdict cannot be obtained, and this gate's whole subject is refusing
  # to grade a subset in silence.
  def self.targets(devops)
    seen = {}
    out = []
    record = lambda do |key, url|
      value = url.to_s.strip
      next if value.empty?

      fingerprint = value.downcase.sub(%r{/+\z}, "")
      next if seen[fingerprint]

      seen[fingerprint] = true
      repo = repo_from_url(value)
      repo = bare_repo(key) if repo.empty?
      out << { repo: repo, url: value, recorded_as: key, readable: pr_url?(value) }
    end

    record.call(nil, devops["pr_url"])
    map = devops["pr_urls"]
    map.keys.sort.each { |key| record.call(key, map[key]) } if map.is_a?(Hash)
    out
  end

  # Does this task carry PRs in more than one place? The gate's single-repo path is
  # untouched whenever this is false, which is what keeps the ordinary task's verdict
  # exactly as it was.
  def self.multi?(devops)
    targets(devops).size > 1
  end

  def self.severity(state)
    CI_SEVERITY.fetch(state.to_s.to_sym, UNKNOWN_CI_SEVERITY)
  end

  # THE VERDICT THAT GOVERNS a multi-PR task — the WORST of them, not the first.
  #
  # Worst-of, not first-non-green, because the ORDER is a record-keeping detail
  # (`pr_url` happens to be recorded first) and a gate whose verdict depends on which
  # URL somebody typed first is a gate that can be steered by the record. Ties break
  # on position so the choice is deterministic.
  #
  # `entries` is [{target:, ci:}]; returns the whole entry, because the caller needs
  # the PR URL the verdict came from — every remedy this gate prints names a repo, and
  # naming the wrong one is the same cross-repo confusion in a different coat.
  def self.governing(entries)
    list = Array(entries)
    return nil if list.empty?

    list.each_with_index.min_by { |entry, index| [severity(entry[:ci][:state]), index] }.first
  end
end
