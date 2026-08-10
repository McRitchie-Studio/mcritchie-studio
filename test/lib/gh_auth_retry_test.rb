# frozen_string_literal: true

# [unit] The mint-once-and-retry classifier behind bin/ship's gh calls.
#
# The classifier is the load-bearing half: a WRONG "yes" wastes a mint and re-runs a
# doomed command, while a wrong "no" leaves the operator hand-minting — which is
# exactly the toil this closes (every ship and every reviewer merge on 2026-08-10).
#
#   ruby -Itest test/lib/gh_auth_retry_test.rb

require "minitest/autorun"
require "tmpdir"
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

  # --- the seam, and the branch it makes reachable ----------------------------
  # Carl's blocker was a NameError on the mint-FAILURE path (`return [first, false]`
  # after `first` was renamed). Ruby parses a bare `first` as a method call, so it is
  # syntactically valid and only crashes at runtime — and that branch was
  # UNREACHABLE from any safe test, because mint shells the real script through the
  # real 1Password (`op whoami` exits 0 on a live workstation), so an unseamed test
  # would mint a REAL production token locally. These seams are what let the failure
  # path be executed instead of merely read.

  def test_token_bin_prefers_the_seam_over_the_real_broker
    assert_equal "/bin/echo", GhAuthRetry.token_bin(env: { "GH_AUTH_TOKEN_BIN" => "/bin/echo" })
    assert GhAuthRetry.token_bin(env: {}).end_with?("gh-token"),
           "defaults to the broker — acquisition lives in ONE place"
  end

  # A mint that cannot run returns nil — the caller then reports gh's ORIGINAL error
  # rather than a confusing one about credentials.
  def test_mint_returns_nil_when_the_broker_is_missing
    assert_nil GhAuthRetry.mint(env: { "GH_AUTH_TOKEN_BIN" => "/nonexistent/gh-token" })
  end

  def test_mint_returns_nil_and_keeps_the_reason_when_the_broker_fails
    Dir.mktmpdir do |dir|
      failing = File.join(dir, "gh-token-fail")
      File.write(failing, "#!/bin/sh\necho 'not signed in' >&2\nexit 1\n")
      File.chmod(0o755, failing)

      assert_nil GhAuthRetry.mint(env: { "GH_AUTH_TOKEN_BIN" => failing })
      assert_includes GhAuthRetry.last_error, "not signed in",
                      "the actionable reason must survive — swallowing it leaves the operator nothing to act on"
    end
  end

  def test_mint_returns_the_token_the_broker_prints
    Dir.mktmpdir do |dir|
      broker = File.join(dir, "gh-token-ok")
      File.write(broker, "#!/bin/sh\necho ghs_sTuBtOkEn\n")
      File.chmod(0o755, broker)

      assert_equal "ghs_sTuBtOkEn", GhAuthRetry.mint(env: { "GH_AUTH_TOKEN_BIN" => broker })
    end
  end

  # The build/review lane identity — deliberately NOT the deployer App, which cannot
  # open or merge PRs by design. A regression here would silently swap lanes.
  def test_defaults_to_the_agent_identity_not_the_deployer
    assert_equal "github.mcritchie-agent", GhAuthRetry::ITEM

    Dir.mktmpdir do |dir|
      broker = File.join(dir, "gh-token-echo")
      File.write(broker, "#!/bin/sh\necho \"$2\"\n") # echoes the --identity value
      File.chmod(0o755, broker)

      assert_equal "agent", GhAuthRetry.mint(env: { "GH_AUTH_TOKEN_BIN" => broker })
      assert_equal "deployer", GhAuthRetry.mint(env: { "GH_AUTH_TOKEN_BIN" => broker }, identity: "deployer")
    end
  end
end
