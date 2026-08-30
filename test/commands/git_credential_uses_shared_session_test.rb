# frozen_string_literal: true

# [unit] The git credential helper must serve the SHARED session, not re-mint.
#
# THE DEFECT THIS EXISTS TO CATCH (measured 2026-08-29). The GitHub App flow is
# PRIVATE KEY -> JWT -> INSTALLATION TOKEN, and GitHub caps that token at an
# hour. `bin/gh-token` already caches it and shares it across sibling agent
# processes. This helper ignored that cache and re-derived a session from the
# key on EVERY git operation — three 1Password reads per push, per fetch, per
# repo, per agent. A day of ordinary work spent the account's 1000-read daily
# quota and stopped every lane for eighteen hours, with eight reviewed tasks
# unable to ship.
#
# WHY THE ASSERTION IS "op WAS NEVER INVOKED" RATHER THAN "the right token came
# back". A helper that returns the correct token while still reading 1Password
# would satisfy any output-only assertion and would not fix the outage at all —
# the cost IS the read. So `op` is replaced by a stub that RECORDS every call,
# and the warm path asserts that log is EMPTY.

require "bundler/setup"
require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"

class GitCredentialUsesSharedSessionTest < Minitest::Test
  BIN = File.expand_path("../../bin/gh-app-git-credential", __dir__)

  def test_a_warm_session_is_served_with_no_1password_read
    in_sandbox(cached: "ghs_WARMSESSION") do |env, oplog|
      out = run_helper(env)

      assert_includes out, "password=ghs_WARMSESSION", "the cached session must be served"
      assert_equal "", File.read(oplog),
                   "a warm git operation must cost ZERO 1Password reads — the READ is the " \
                   "cost that exhausted the daily quota, so returning the right token while " \
                   "still reading would leave the outage exactly where it was"
    end
  end

  # THE FALLBACK IS NOT OPTIONAL. This helper sits on the path every git
  # operation depends on, so the cache must be an OPTIMISATION rather than a
  # dependency: if bin/gh-token is missing, non-executable, or silent, the
  # original mint path must still work. A slow git operation is survivable; a
  # broken one is not.
  def test_a_cold_cache_falls_through_to_the_mint_path
    in_sandbox(cached: "") do |env, oplog|
      out = run_helper(env)

      assert_includes out, "password=ghs_MINTED", "a cache miss must still mint"
      refute_empty File.read(oplog), "the mint path is expected to read 1Password"
    end
  end

  def test_a_missing_token_command_falls_through_rather_than_failing
    in_sandbox(cached: nil) do |env, _oplog|
      env["GH_APP_TOKEN_CMD"] = "/nonexistent/gh-token"

      assert_includes run_helper(env), "password=ghs_MINTED",
                      "an absent bin/gh-token must degrade to minting, never break git"
    end
  end

  # GUARD THE GUARD. A cache that returns junk — a truncated read, an error
  # string, a stray newline — must NOT be handed to git as a password. Without
  # the shape check the helper would cheerfully serve "could not read the agent
  # App credentials" as a credential and git would report an auth failure whose
  # cause is three layers away.
  def test_a_malformed_cache_value_is_refused_and_falls_through
    in_sandbox(cached: "could not read the agent App credentials") do |env, _oplog|
      out = run_helper(env)

      refute_includes out, "could not read", "junk must never be served as a password"
      assert_includes out, "password=ghs_MINTED", "and it must fall through to the mint"
    end
  end

  private

  def in_sandbox(cached:)
    Dir.mktmpdir("git-cred") do |dir|
      oplog = File.join(dir, "op-calls.log")

      # `op` records every invocation AND answers plausibly, because the mint
      # path pipes `item get --format json` into a real JSON parser — a stub that
      # only logged would make the fallback tests fail for the wrong reason and
      # tell us nothing about the fallback itself.
      write_stub(dir, "op", <<~SH)
        echo "$@" >> #{oplog}
        case "$1" in
          item) echo '{"files":[{"name":"agent.private-key.pem"}]}' ;;
          *)    echo "stub-secret" ;;
        esac
      SH
      write_stub(dir, "mint", "echo ghs_MINTED")
      write_stub(dir, "gh-token", cached.nil? ? "exit 1" : "printf '%s' #{cached.inspect}")

      env = {
        "GH_APP_OP_BIN" => File.join(dir, "op"),
        "GH_APP_MINT_CMD" => File.join(dir, "mint"),
        "GH_APP_TOKEN_CMD" => File.join(dir, "gh-token")
      }
      File.write(oplog, "")
      yield env, oplog
    end
  end

  def write_stub(dir, name, body)
    path = File.join(dir, name)
    File.write(path, "#!/bin/sh\n#{body}\n")
    FileUtils.chmod(0o755, path)
    path
  end

  def run_helper(env)
    out, = Open3.capture2e(env, BIN, "get")
    out
  end
end
