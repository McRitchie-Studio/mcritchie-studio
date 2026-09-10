# frozen_string_literal: true

require "json"
require_relative "ci_status"

# WHICH BASE DID THIS PR'S CI ACTUALLY TEST? (/tasks/stale-merge-ref-passes-freshness)
#
# A pull_request run tests refs/pull/N/merge as GitHub built it when the run was
# TRIGGERED — PR head merged onto the base tip of that moment — and then takes many
# minutes. The base-movement audit used to ask "did this base commit land before the run
# COMPLETED?", which calls any commit landing inside the run "covered" while the tree CI
# tested never held it. MEASURED on tm#682, 2026-09-10: merge ref built 06:19Z; tm#677
# landed 06:26:04Z and tm#678 06:40:16Z, both before the run finished; the gate waved it
# through.
#
# The exact answer is not a clock at all. GitHub records, on each workflow run, the base
# SHA its event saw (`pull_requests[].base.sha`), and it does NOT move with the base —
# measured 2026-09-10 on open PR ms#1247: a three-day-old run still reports df21eca3
# while `accepted` sat dozens of merges later. A base commit is covered iff it is an
# ANCESTOR of that SHA, which is also immune to "committer date is not landing order".
#
# UNRESOLVED IS A FIRST-CLASS ANSWER, not an error. The array is empty on fork PRs and on
# merged PRs, and a head can carry runs from DIFFERENT events (a base edit re-triggers on
# the same head) — more than one distinct base means the green is not one tree, so this
# refuses to pick. The caller must say the window went unchecked; it must never quietly
# substitute the completion clock as if it answered the same question.
module MergeRefBase
  module_function

  SHA = /\A\h{7,40}\z/

  # => { state: :resolved, sha: } | { state: :unresolved, reason: Symbol }
  #
  # `injected` is the test seam (DOR_CHECK_CI_TESTED_BASE): a SHA resolves to itself; any
  # other non-blank value is an injected "could not resolve". `live: false` is the
  # caller's statement that CI itself was injected, so a live GitHub read would grade a
  # run nobody asked about — it answers :not_read instead.
  def resolve(pr_url, head_sha, injected: nil, live: true)
    seam = injected.to_s.strip
    unless seam.empty?
      return seam.match?(SHA) ? { state: :resolved, sha: seam } : { state: :unresolved, reason: :injected }
    end
    return { state: :unresolved, reason: :not_read } unless live

    m = pr_url.to_s.match(%r{github\.com/([^/\s]+)/([^/\s]+)/pull/(\d+)})
    return { state: :unresolved, reason: :no_pr } unless m
    return { state: :unresolved, reason: :no_head } unless head_sha.to_s.match?(/\A\h{40}\z/)

    body, ok = CiStatus.gh_read_status(
      "api", "repos/#{m[1]}/#{m[2]}/actions/runs?head_sha=#{head_sha}&event=pull_request&per_page=100"
    )
    return { state: :unresolved, reason: :unreadable } unless ok

    bases_from(body, m[3].to_i)
  end

  # The distinct base SHAs this PR's runs on this head were built against.
  def bases_from(body, number)
    runs = JSON.parse(body.to_s)["workflow_runs"]
    bases = Array(runs).flat_map { |run| Array(run["pull_requests"]) }
                       .select { |pr| pr["number"] == number }
                       .filter_map { |pr| pr.dig("base", "sha") }.uniq
    return { state: :unresolved, reason: :no_run } if bases.empty?
    return { state: :unresolved, reason: :ambiguous } if bases.size > 1

    { state: :resolved, sha: bases.first }
  rescue JSON::ParserError, TypeError
    { state: :unresolved, reason: :unreadable }
  end

  # One sentence per reason, for the verdict. Keyed so a new reason cannot render blank.
  def reason_text(reason)
    {
      injected: "the tested base was injected as unresolvable",
      not_read: "CI was injected, so no run was read",
      no_pr: "no PR URL to read runs from",
      no_head: "the PR head could not be resolved",
      unreadable: "GitHub refused or garbled the runs read",
      no_run: "no pull_request run on this head names this PR (fork PR, or the PR already merged)",
      ambiguous: "runs on this head were built against MORE THAN ONE base, so the green is not one tree",
      not_local: "the tested base is not in this checkout, so ancestry could not be asked",
      multi_pr: "this task carries MORE THAN ONE PR, so the governing run may belong to another repo"
    }.fetch(reason, "unresolved (#{reason})")
  end
end
