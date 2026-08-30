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


  # ── THE ERASE BRANCH ────────────────────────────────────────────────────────
  #
  # PROVEN AGAINST GIT, not assumed. On 2026-08-30 a local server answering every
  # request with 401 was pointed at by an isolated GIT_CONFIG_GLOBAL, and git
  # invoked this helper twice: `get`, then `erase` with the rejected password on
  # stdin. That second call is the ONLY notice a credential helper ever gets that
  # a token has gone bad — it never sees the 401 — so without this branch a
  # revoked session is re-served on every git operation until the clock retires it.
  def test_an_erase_retires_the_rejected_session
    in_sandbox(cached: "ghs_REVOKED") do |env, _oplog|
      log = File.join(File.dirname(env["GH_APP_TOKEN_CMD"]), "token-calls.log")
      write_stub(File.dirname(env["GH_APP_TOKEN_CMD"]), "gh-token", %(echo "$@" >> #{log}))

      run_helper(env, "erase", stdin: "protocol=https\nhost=github.com\n" \
                                      "username=x-access-token\npassword=ghs_REVOKED\n")

      assert_includes File.read(log), "--reject ghs_REVOKED",
                      "the rejected password must be handed to bin/gh-token so the shared " \
                      "cache stops serving it to every sibling agent"
    end
  end

  # A credential helper must not be able to make a failing git operation fail
  # WORSE. `erase` is bookkeeping on a path git has already given up on, so every
  # way it can go wrong — a missing bin/gh-token here — still exits 0.
  def test_an_erase_never_fails_the_git_operation
    in_sandbox(cached: nil) do |env, _oplog|
      env["GH_APP_TOKEN_CMD"] = "/nonexistent/gh-token"

      _out, status = run_helper_status(env, "erase", stdin: "password=ghs_REVOKED\n")

      assert status.success?, "erase must exit 0 even when the retirement itself could not run"
    end
  end

  # An erase with nothing to act on must not reach for 1Password. This is the same
  # property the warm-path test guards, on the other action: the READ is the cost.
  def test_an_erase_without_a_password_costs_nothing
    in_sandbox(cached: "ghs_WARMSESSION") do |env, oplog|
      run_helper(env, "erase", stdin: "protocol=https\nhost=github.com\n")

      assert_equal "", File.read(oplog), "an erase must never mint or read 1Password"
    end
  end

  # `store` is git offering to persist a credential whose lifecycle we own. Writing
  # it anywhere would fork the source of truth away from bin/gh-token's cache.
  def test_an_unrecognised_action_is_a_silent_no_op
    in_sandbox(cached: "ghs_WARMSESSION") do |env, oplog|
      out, status = run_helper_status(env, "store", stdin: "password=ghs_WARMSESSION\n")

      assert status.success?
      assert_equal "", out.strip, "store must produce no output"
      assert_equal "", File.read(oplog), "and must not touch 1Password"
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

  def run_helper(env, action = "get", stdin: "")
    run_helper_status(env, action, stdin: stdin).first
  end

  def run_helper_status(env, action = "get", stdin: "")
    Open3.capture2e(env, BIN, action, stdin_data: stdin)
  end
end
