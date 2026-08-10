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

  def test_mint_bin_prefers_the_seam_over_the_real_script
    assert_equal "/bin/echo", GhAuthRetry.mint_bin(env: { "GH_AUTH_MINT_BIN" => "/bin/echo" })
    assert GhAuthRetry.mint_bin(env: {}).end_with?("gh-app-mint-token"), "defaults to the real script"
  end

  def test_op_bin_prefers_the_seam
    assert_equal "/bin/echo", GhAuthRetry.op_bin(env: { "GH_AUTH_OP_BIN" => "/bin/echo" })
    assert_equal GhAuthRetry::OP_BIN, GhAuthRetry.op_bin(env: {})
  end

  # A mint that cannot run returns nil — the caller then reports gh's ORIGINAL error
  # rather than a confusing one about credentials.
  def test_mint_returns_nil_when_the_mint_binary_is_missing
    assert_nil GhAuthRetry.mint(env: { "GH_AUTH_MINT_BIN" => "/nonexistent/mint" })
  end

  def test_mint_returns_nil_when_the_secret_read_fails
    Dir.mktmpdir do |dir|
      failing_op = File.join(dir, "op-fail")
      File.write(failing_op, "#!/bin/sh\necho 'not signed in' >&2\nexit 1\n")
      File.chmod(0o755, failing_op)

      assert_nil GhAuthRetry.mint(env: { "GH_AUTH_MINT_BIN" => "/bin/echo", "GH_AUTH_OP_BIN" => failing_op })
      assert_includes GhAuthRetry.last_error, "not signed in",
                      "the actionable reason must survive — swallowing it leaves the operator nothing to act on"
    end
  end

  def test_mint_returns_the_token_when_everything_works
    Dir.mktmpdir do |dir|
      op = File.join(dir, "op-ok")
      File.write(op, "#!/bin/sh\necho stub-secret\n")
      File.chmod(0o755, op)
      mint = File.join(dir, "mint-ok")
      File.write(mint, "#!/bin/sh\necho ghs_sTuBtOkEn\n")
      File.chmod(0o755, mint)

      assert_equal "ghs_sTuBtOkEn",
                   GhAuthRetry.mint(env: { "GH_AUTH_MINT_BIN" => mint, "GH_AUTH_OP_BIN" => op })
    end
  end

  def test_uses_the_agent_app_identity_not_the_deployer
    assert_equal "github.mcritchie-agent", GhAuthRetry::ITEM
    assert_includes GhAuthRetry::APP_ID_REF, "github.mcritchie-agent"
    refute_includes GhAuthRetry::PEM_REF, "deployer"
  end
end
