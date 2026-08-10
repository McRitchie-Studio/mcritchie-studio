# frozen_string_literal: true

# [unit] The mint-once-and-retry classifier behind bin/ship's gh calls.
#
# The classifier is the load-bearing half: a WRONG "yes" wastes a mint and re-runs a
# doomed command, while a wrong "no" leaves the operator hand-minting — which is
# exactly the toil this closes (every ship and every reviewer merge on 2026-08-10).
#
#   ruby -Itest test/lib/gh_auth_retry_test.rb

require "minitest/autorun"
require_relative "../../bin/lib/gh_auth_retry"

class GhAuthRetryTest < Minitest::Test
  # The real strings gh returned during the 2026-08-10 outage window, verbatim —
  # a classifier tested only against invented text proves nothing about the wild.
  REAL_AUTH_FAILURES = [
    "pull request create failed: GraphQL: Resource not accessible by personal access token (createPullRequest)",
    "GraphQL: Resource not accessible by personal access token (mergePullRequest)",
    "HTTP 401: Bad credentials (https://api.github.com/graphql)"
  ].freeze

  # Failures that are about the WORK, not the credential. Minting for these would
  # burn a token and fail again, slower — and would bury the real cause.
  NON_AUTH_FAILURES = [
    "failed to run git: merge conflict in CHANGELOG.md",
    "pull request create failed: a pull request for branch \"feat/x\" already exists",
    "GraphQL: Base branch was modified. Review and try the merge again.",
    "X required status check is expected."
  ].freeze

  def test_recognizes_every_real_auth_failure
    REAL_AUTH_FAILURES.each do |line|
      assert GhAuthRetry.auth_failure?(line), "must mint-and-retry for: #{line}"
    end
  end

  def test_leaves_work_failures_alone
    NON_AUTH_FAILURES.each do |line|
      refute GhAuthRetry.auth_failure?(line), "must NOT mint for: #{line}"
    end
  end

  def test_blank_output_is_not_an_auth_failure
    refute GhAuthRetry.auth_failure?("")
    refute GhAuthRetry.auth_failure?(nil)
  end

  # Case and surrounding noise vary per gh verb and version; the match is on the
  # shape of the refusal, not one exact sentence.
  def test_matching_is_case_insensitive_and_substring
    assert GhAuthRetry.auth_failure?("...\nRESOURCE NOT ACCESSIBLE by personal access token\n...")
  end

  # The build/review lane identity — deliberately NOT the deployer App, which cannot
  # open or merge PRs by design. A regression here would silently swap lanes.
  def test_uses_the_agent_app_identity_not_the_deployer
    assert_equal "github.mcritchie-agent", GhAuthRetry::ITEM
    assert_includes GhAuthRetry::APP_ID_REF, "github.mcritchie-agent"
    refute_includes GhAuthRetry::PEM_REF, "deployer"
  end
end
