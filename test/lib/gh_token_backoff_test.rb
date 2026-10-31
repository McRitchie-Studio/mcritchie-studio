# frozen_string_literal: true

# [unit] bin/gh-token serves the shared session and reads 1Password only on a miss
# or expiry, and never while 1Password is known to be down (one-way-into-1password).
#
# WHY. On 2026-10-30 and 2026-10-31 the dispatcher's harness probe asked for a token
# once a minute with an expired cache and a hung, then rate-limited, 1Password. Each
# beat read `op` again: 1,075 metered failed attempts in two windows. Two seams close
# it: `--cached-only` (a watcher's read that never reaches op) and the account-wide
# backoff (a hang or the rate limit, recorded where every sibling sees it).
#
# Every case runs against stub `op` and mint scripts and a tmpdir cache.
#   ruby -Itest test/lib/gh_token_backoff_test.rb

require "minitest/autorun"
require "json"
require "open3"
require "tmpdir"
require "fileutils"
require "time"

class GhTokenBackoffTest < Minitest::Test
  BIN = File.expand_path("../../bin/gh-token", __dir__)

  # +op_body+ is the stub's shell body after it logs its argv.
  def env_for(dir, op_body: "echo stub-secret")
    mint = File.join(dir, "mint-stub")
    File.write(mint, "#!/bin/sh\necho 'ghs_sTuBtOkEn'\n")
    File.chmod(0o755, mint)
    op = File.join(dir, "op-stub")
    File.write(op, "#!/bin/sh\necho \"$@\" >> #{File.join(dir, 'op-calls.log')}\n#{op_body}\n")
    File.chmod(0o755, op)
    { "CLAUDE_PROJECTS_DIR" => dir, "GH_TOKEN_MINT_BIN" => mint, "GH_TOKEN_OP_BIN" => op,
      "MCR_OP_DEADLINE" => "0.4", "GH_APP_ITEM" => nil, "MCR_OP_NO_BACKOFF" => nil }
  end

  def run_token(env, *args) = Open3.capture3(env, BIN, *args)

  def op_calls(dir)
    path = File.join(dir, "op-calls.log")
    File.exist?(path) ? File.readlines(path).size : 0
  end

  def manifest_entry(dir)
    path = File.join(dir, ".secret-cache", "manifest.json")
    File.exist?(path) ? JSON.parse(File.read(path)).dig("entries", "github.agent") || {} : {}
  end

  # ── --cached-only ────────────────────────────────────────────────────────────

  def test_cached_only_with_nothing_cached_exits_3_and_never_reads_op
    Dir.mktmpdir do |dir|
      out, _err, status = run_token(env_for(dir), "--cached-only")

      assert_equal 3, status.exitstatus
      assert_empty out
      assert_equal 0, op_calls(dir), "a watcher's read must never reach 1Password"
    end
  end

  def test_cached_only_serves_the_shared_session
    Dir.mktmpdir do |dir|
      env = env_for(dir)
      run_token(env)
      before = op_calls(dir)
      out, _err, status = run_token(env, "--cached-only")

      assert status.success?
      assert_equal "ghs_sTuBtOkEn", out.strip
      assert_equal before, op_calls(dir)
    end
  end

  # ── the account-wide backoff ─────────────────────────────────────────────────

  def test_a_hung_1password_backs_every_sibling_off
    Dir.mktmpdir do |dir|
      env = env_for(dir, op_body: "exec sleep 5")
      _out, _err, first = run_token(env)
      refute first.success?
      after_first = op_calls(dir)
      assert_equal 2, after_first, "control: the first refresh tried op (one attempt and its uncached retry)"
      assert_equal "hung", manifest_entry(dir)["backoff_reason"]

      _out, err, second = run_token(env)
      assert_equal 75, second.exitstatus, "HUNG_EXIT, so the git credential helper spends no read of its own"
      assert_equal after_first, op_calls(dir), "inside the window no process reads 1Password"
      assert_match(/MCR_OP_NO_BACKOFF=1 bin\/gh-token\z/, err.strip, "the refusal ends on the command that skips it")
    end
  end

  def test_the_rate_limit_backs_off_and_the_override_skips_it
    Dir.mktmpdir do |dir|
      env = env_for(dir, op_body: "echo '[ERROR] Too many requests' >&2; exit 1")
      _out, _err, first = run_token(env)
      assert_equal 75, first.exitstatus, "the rate limit stops the credential helper's own reads too"
      assert_equal "rate-limited", manifest_entry(dir)["backoff_reason"]
      calls = op_calls(dir)

      run_token(env)
      assert_equal calls, op_calls(dir), "backing off: no read"

      healthy = env.merge("MCR_OP_NO_BACKOFF" => "1")
      File.write(env["GH_TOKEN_OP_BIN"], "#!/bin/sh\necho \"$@\" >> #{File.join(dir, 'op-calls.log')}\necho stub-secret\n")
      out, _err, status = run_token(healthy)
      assert status.success?
      assert_equal "ghs_sTuBtOkEn", out.strip
      assert_operator op_calls(dir), :>, calls, "the override reads op"
      assert_nil manifest_entry(dir)["backoff_until"], "a successful mint clears the backoff"
    end
  end

  # A failure one shell owns (its token missing, a wrong vault) must not stall every
  # healthy agent on the Mac: a launchd job with no token would otherwise do exactly that.
  def test_a_failure_one_shell_owns_does_not_back_off
    Dir.mktmpdir do |dir|
      env = env_for(dir, op_body: "echo '[ERROR] no account found' >&2; exit 1")
      run_token(env)
      calls = op_calls(dir)
      assert_nil manifest_entry(dir)["backoff_until"]

      run_token(env)
      assert_operator op_calls(dir), :>, calls, "a per-shell failure leaves the next caller free to try"
    end
  end

  # The deployer is never cached and never backed off: an operator who has just
  # sourced the admin profile must not wait out a window another process opened.
  def test_the_deployer_is_not_backed_off
    Dir.mktmpdir do |dir|
      env = env_for(dir, op_body: "echo '[ERROR] Too many requests' >&2; exit 1")
      run_token(env, "--identity", "deployer")
      calls = op_calls(dir)
      run_token(env, "--identity", "deployer")
      assert_operator op_calls(dir), :>, calls
    end
  end

  # ── [integration] the meter sees exactly one mint, and nothing on a hit ──────

  def test_integration_a_mint_then_a_hit_records_one_mint_in_op_reads
    Dir.mktmpdir do |dir|
      env = env_for(dir)
      run_token(env)
      run_token(env)
      run_token(env, "--cached-only")

      out, _err, status = Open3.capture3(env, File.expand_path("../../bin/op-reads", __dir__), "--all", "--tail", "50", "--json")
      assert status.success?, out
      reads = JSON.parse(out).select { |r| r["caller"] == "gh-token" }
      assert_equal 2, reads.size, "one mint is two reads (app-id and the key); the two cache hits add none"
      assert_equal %w[ok ok], reads.map { |r| r["outcome"] }
      assert_equal 2, op_calls(dir), "the stub agrees with the meter"
    end
  end
end
