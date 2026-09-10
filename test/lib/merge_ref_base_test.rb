# frozen_string_literal: true

require "minitest/autorun"
require "json"
require_relative "../../bin/lib/merge_ref_base"

# [unit] The reader that answers "which base did this PR's CI test?" Its whole contract is
# that UNRESOLVED is a real answer with a reason, never a silent nil the caller mistakes for
# "nothing moved" (/tasks/stale-merge-ref-passes-freshness).
class MergeRefBaseTest < Minitest::Test
  A = "a" * 40
  B = "b" * 40

  def runs(*prs) = JSON.generate("workflow_runs" => prs.map { |pr| { "pull_requests" => pr } })
  def pr(number, base) = [{ "number" => number, "base" => { "sha" => base } }]

  def test_one_base_across_the_runs_resolves
    assert_equal({ state: :resolved, sha: A }, MergeRefBase.bases_from(runs(pr(7, A), pr(7, A)), 7))
  end

  def test_two_bases_on_one_head_is_ambiguous_not_a_pick
    assert_equal :ambiguous, MergeRefBase.bases_from(runs(pr(7, A), pr(7, B)), 7)[:reason]
  end

  def test_runs_naming_another_pr_or_none_do_not_resolve
    assert_equal :no_run, MergeRefBase.bases_from(runs(pr(8, A), []), 7)[:reason],
                 "an emptied pull_requests array (merged or fork PR) must not resolve"
  end

  def test_a_garbled_body_is_unreadable
    assert_equal :unreadable, MergeRefBase.bases_from("HTTP 403: Resource not accessible", 7)[:reason]
  end

  def test_the_seam_resolves_a_sha_and_refuses_anything_else
    assert_equal({ state: :resolved, sha: A }, MergeRefBase.resolve(nil, nil, injected: A))
    assert_equal :injected, MergeRefBase.resolve(nil, nil, injected: "none")[:reason]
  end

  def test_injected_ci_never_triggers_a_live_read
    assert_equal :not_read, MergeRefBase.resolve("https://github.com/o/r/pull/7", A, live: false)[:reason]
  end

  def test_every_reason_renders_a_sentence
    %i[injected not_read no_pr no_head unreadable no_run ambiguous not_local multi_pr].each do |reason|
      refute_match(/\Aunresolved \(/, MergeRefBase.reason_text(reason), "#{reason} has no sentence")
    end
  end
end
