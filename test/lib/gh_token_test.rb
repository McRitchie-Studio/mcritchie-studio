# frozen_string_literal: true

# [unit] bin/gh-token — the ONE place a GitHub token comes from.
#
# The seams (GH_TOKEN_MINT_BIN, GH_TOKEN_OP_BIN, CLAUDE_PROJECTS_DIR) mean every
# case below runs against stub scripts and a tmpdir cache. No real 1Password read,
# no real mint, no real token — which matters, because `op` is signed in on a live
# workstation and an unseamed test here would mint production credentials.
#
#   ruby -Itest test/lib/gh_token_test.rb

require "minitest/autorun"
require "json"
require "open3"
require "tmpdir"
require "fileutils"
require "time"

class GhTokenTest < Minitest::Test
  BIN = File.expand_path("../../bin/gh-token", __dir__)
  # Anything shaped like a GitHub credential. The leak this file exists to prevent
  # was a token printed by a flag whose entire job is NOT printing one.
  TOKEN_SHAPED = /ghs_[A-Za-z0-9_]+|ghp_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+/

  def with_env(dir, mint_output: "ghs_sTuBtOkEn", mint_status: 0)
    mint = File.join(dir, "mint-stub")
    File.write(mint, "#!/bin/sh\necho '#{mint_output}'\nexit #{mint_status}\n")
    File.chmod(0o755, mint)
    op = File.join(dir, "op-stub")
    File.write(op, "#!/bin/sh\necho stub-secret\n")
    File.chmod(0o755, op)

    { "CLAUDE_PROJECTS_DIR" => dir, "GH_TOKEN_MINT_BIN" => mint, "GH_TOKEN_OP_BIN" => op }
  end

  def run_token(env, *args)
    Open3.capture3(env, BIN, *args)
  end

  def store_path(dir) = File.join(dir, ".agents", "github-tokens.json")
  def store(dir) = JSON.parse(File.read(store_path(dir)))

  def test_mints_and_caches_on_a_cold_start
    Dir.mktmpdir do |dir|
      out, _err, status = run_token(with_env(dir))

      assert status.success?
      assert_equal "ghs_sTuBtOkEn", out.strip
      assert_equal "a", store(dir).dig("agent", "active"), "the first mint lands in slot a"
      refute_nil store(dir).dig("agent", "a", "created_at")
    end
  end

  # The cache is the point: a second call inside the freshness window must NOT mint.
  def test_a_fresh_cached_token_is_reused_without_minting
    Dir.mktmpdir do |dir|
      env = with_env(dir)
      run_token(env)
      out, = run_token(env.merge("GH_TOKEN_MINT_BIN" => "/nonexistent/mint"))

      assert_equal "ghs_sTuBtOkEn", out.strip, "served from cache — the mint was never consulted"
    end
  end

  # The operator's A/B design: a fresh mint lands in the INACTIVE slot and flips, so
  # the previous token survives intact for an agent already using it.
  def test_a_stale_token_mints_into_the_other_slot_and_toggles
    Dir.mktmpdir do |dir|
      env = with_env(dir)
      run_token(env)

      # Age slot a past the refresh window; nothing else changes.
      data = store(dir)
      data["agent"]["a"]["created_at"] = (Time.now.utc - 3300).iso8601
      File.write(store_path(dir), JSON.generate(data))

      out, = run_token(env.merge("GH_TOKEN_MINT_BIN" => begin
        m = File.join(dir, "mint2")
        File.write(m, "#!/bin/sh\necho ghs_SECOND\n")
        File.chmod(0o755, m)
        m
      end))

      assert_equal "ghs_SECOND", out.strip
      assert_equal "b", store(dir).dig("agent", "active"), "the new token toggles to slot b"
      assert_equal "ghs_sTuBtOkEn", store(dir).dig("agent", "a", "token"),
                   "the PREVIOUS token is preserved — an agent mid-operation is never cut off"
    end
  end

  # Read rule: newest by created_at, never "whichever is flagged active". A toggle
  # must never be able to serve something older than what it replaced.
  def test_the_newest_token_wins_even_if_active_points_at_the_older_slot
    Dir.mktmpdir do |dir|
      env = with_env(dir)
      run_token(env)
      FileUtils.mkdir_p(File.dirname(store_path(dir)))
      File.write(store_path(dir), JSON.generate(
        "agent" => {
          "active" => "a",
          "a" => { "token" => "ghs_OLDER", "created_at" => (Time.now.utc - 600).iso8601 },
          "b" => { "token" => "ghs_NEWER", "created_at" => Time.now.utc.iso8601 }
        }
      ))

      out, = run_token(env)
      assert_equal "ghs_NEWER", out.strip
    end
  end

  # Two Apps with deliberately different powers: a merge call must never receive a
  # deployer token, so the identities cache separately.
  def test_identities_cache_independently
    Dir.mktmpdir do |dir|
      env = with_env(dir)
      run_token(env)
      run_token(env, "--identity", "deployer")

      assert store(dir).key?("agent")
      assert store(dir).key?("deployer")
    end
  end

  def test_an_unknown_identity_is_refused
    Dir.mktmpdir do |dir|
      _out, err, status = run_token(with_env(dir), "--identity", "nobody")
      refute status.success?
      assert_match(/unknown identity/, err)
    end
  end

  # THE LEAK, pinned. `--status` used `status and exit 0`; `status` returns nil, the
  # `and` short-circuited, the exit never ran, and execution fell through to the bare
  # token print — putting a live credential on a terminal on 2026-08-10. A flag whose
  # whole purpose is "show state WITHOUT the secret" must never emit one.
  def test_status_never_prints_a_token
    Dir.mktmpdir do |dir|
      env = with_env(dir)
      run_token(env) # populate the cache so there IS a token to leak

      out, err, status = run_token(env, "--status")

      assert status.success?
      refute_match TOKEN_SHAPED, out, "--status must never print a token"
      refute_match TOKEN_SHAPED, err
      assert_match(/agent/, out, "…while still reporting the cache state")
    end
  end

  def test_status_on_an_empty_cache_prints_no_token
    Dir.mktmpdir do |dir|
      out, err, = run_token(with_env(dir), "--status")
      refute_match TOKEN_SHAPED, out
      refute_match TOKEN_SHAPED, err
    end
  end

  # Help is the other non-token path; the same fall-through would leak there too.
  def test_help_never_prints_a_token
    Dir.mktmpdir do |dir|
      env = with_env(dir)
      run_token(env)
      out, err, = run_token(env, "--help")
      refute_match TOKEN_SHAPED, out
      refute_match TOKEN_SHAPED, err
    end
  end

  # The cache holds a live credential: it must not be world- or group-readable.
  def test_the_cache_file_is_owner_only
    Dir.mktmpdir do |dir|
      run_token(with_env(dir))
      assert_equal "600", format("%o", File.stat(store_path(dir)).mode & 0o777)
    end
  end

  def test_a_failing_mint_exits_nonzero_and_prints_no_token
    Dir.mktmpdir do |dir|
      out, _err, status = run_token(with_env(dir, mint_output: "", mint_status: 1))
      refute status.success?
      refute_match TOKEN_SHAPED, out
    end
  end

  # A corrupt cache is a cache MISS, never a failure — we can always mint again.
  def test_a_corrupt_cache_degrades_to_a_fresh_mint
    Dir.mktmpdir do |dir|
      env = with_env(dir)
      FileUtils.mkdir_p(File.dirname(store_path(dir)))
      File.write(store_path(dir), "{not json")

      out, _err, status = run_token(env)
      assert status.success?
      assert_equal "ghs_sTuBtOkEn", out.strip
    end
  end
end
