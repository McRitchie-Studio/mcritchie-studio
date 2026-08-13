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
  #
  # THE CHARACTER CLASS INCLUDES `.` AND `-` ON PURPOSE. It used to be `[A-Za-z0-9_]+`,
  # which is safe in the `refute_match` DETECTOR role this file uses it in — a dotted
  # installation token still trips it on the prefix — but it is the shape
  # docs/agents/modules/credentials.md now warns against, because a modern token is a
  # dotted JWT (`ghs_<base64>.<base64>.<sig>`) and the same class used for REDACTION
  # stops at the first dot and passes the signature through. That is not hypothetical:
  # it turned a redaction into a leak on 2026-08-13. Aligned here so nobody copies the
  # narrow version out of a test file into a context where it has to be right.
  TOKEN_SHAPED = /gh[psou]_[A-Za-z0-9_.-]{8,}|github_pat_[A-Za-z0-9_.-]{8,}/
  DOTTED_TOKEN = "ghs_16C7e42F292c6912E7710c838347Ae178B4a.eyJhbGciOiJIUzI1NiJ9.q-3sT_signature"

  # The control for every refute_match in this file: a guard that matches nothing
  # proves nothing.
  def test_the_leak_guard_matches_the_token_shapes_it_must_catch
    assert_match TOKEN_SHAPED, DOTTED_TOKEN, "the shape GitHub actually issues"
    assert_match TOKEN_SHAPED, "ghs_sTuBtOkEn", "the shape this file's stubs issue"
    refute_match TOKEN_SHAPED, "agent: active=a", "cache state is not a token"
    refute_match TOKEN_SHAPED, "sha256:bcdf2f7e20ce", "a digest is not a token"
  end

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

  # THE REGRESSION, pinned at the command's own boundary. `--identity` with the value
  # eaten — `bin/gh-token --identity "$VAR"` with VAR unset, or `--identity` as the last
  # argument — used to abort. It briefly did not: the arg loop turned the missing value
  # into "" via `.to_s.strip`, the resolver read "" as "the caller said nothing", and the
  # command minted and cached the AGENT App, which holds `pull_requests: write`.
  #
  # BOTH SPELLINGS, because they arrive by different routes and only one of them looks
  # like a mistake: a trailing flag is a typo, an empty shell variable is a Tuesday.
  EMPTY_IDENTITY_ARGV = {
    "a trailing --identity" => ["--identity"],
    "an empty value" => ["--identity", ""],
    "a whitespace value" => ["--identity", "   "]
  }.freeze

  def test_an_empty_identity_value_aborts_without_minting_or_printing_a_token
    EMPTY_IDENTITY_ARGV.each do |label, argv|
      Dir.mktmpdir do |dir|
        out, err, status = run_token(with_env(dir), *argv)

        refute status.success?, "#{label} must abort — silently minting `agent` here IS the bug"
        assert_equal 0, out.bytesize,
                     "#{label} put #{out.bytesize} bytes on stdout; an error path must emit NOTHING, " \
                     "because stdout is this command's token channel"
        refute_match TOKEN_SHAPED, out
        refute_match TOKEN_SHAPED, err
        assert_match(/empty/i, err, "#{label} must say what was wrong with the ARGUMENT")
        refute File.exist?(store_path(dir)), "#{label} minted nothing, so it may cache nothing"
      end
    end
  end

  # The privilege reading of the same case, stated separately: whatever the abort
  # message says, the observable outcome must never be an agent-slot token.
  def test_an_empty_identity_never_lands_a_token_in_the_privileged_slot
    Dir.mktmpdir do |dir|
      run_token(with_env(dir), "--identity")

      refute File.exist?(store_path(dir)), "no cache file at all"
    end

    Dir.mktmpdir do |dir|
      env = with_env(dir).merge("GH_APP_ITEM" => "github.mcritchie-deployer")
      _out, _err, status = run_token(env, "--identity")

      refute status.success?, "a lost --identity must not fall through to the ambient lane either"
      refute File.exist?(store_path(dir))
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
  #
  # ASSERTED AS A PROPERTY, NOT A SPELLING. This case used to pin only `{not json`,
  # which raises inside JSON.parse and so exercised only the rescue. Every OTHER
  # corruption below parses CLEANLY and then blew up downstream — `[]` with a
  # TypeError, `null` with a NoMethodError, a scalar entry with an IndexError — so
  # the command that every `gh` call depends on died on an unhandled stack trace and
  # wedged every agent until a human deleted the file. One spelling green while four
  # shapes crashed is exactly the gap a property closes.
  CORRUPT_CACHES = {
    "unparseable" => "{not json",
    "a JSON array" => "[]",
    "JSON null" => "null",
    "a bare scalar" => '"scalar"',
    "a scalar identity entry" => '{"agent":"oops"}',
    "a slot that is not an object" => '{"agent":{"active":"a","a":"nope"}}'
  }.freeze

  def test_every_corrupt_cache_shape_degrades_to_a_fresh_mint
    CORRUPT_CACHES.each do |label, payload|
      Dir.mktmpdir do |dir|
        env = with_env(dir)
        FileUtils.mkdir_p(File.dirname(store_path(dir)))
        File.write(store_path(dir), payload)

        out, err, status = run_token(env)
        assert status.success?, "#{label} must degrade to a mint, not crash — got: #{err}"
        assert_equal "ghs_sTuBtOkEn", out.strip, "#{label} must serve a freshly minted token"
        refute_match(/Error\b|backtrace|\.rb:\d+:in/, err, "#{label} must not surface a Ruby stack trace")
      end
    end
  end

  # --- the lane, and the cache slot it must land in ---------------------------
  # This broker used to read ONLY --identity and ignore GH_APP_ITEM, so a ship
  # session (which exports the deployer ITEM, exactly as `git` requires) was handed
  # the AGENT App — the one holding `pull_requests: write`, which the deployer is
  # denied by design. The cache slot is the observable proof of which App was asked
  # for, so assert there rather than on a flag having been forwarded.
  def test_gh_app_item_selects_the_deployer_lane
    Dir.mktmpdir do |dir|
      env = with_env(dir).merge("GH_APP_ITEM" => "github.mcritchie-deployer")
      out, err, status = run_token(env)

      assert status.success?, err
      assert_equal "ghs_sTuBtOkEn", out.strip
      refute_nil store(dir)["deployer"], "the ship lane's token must be cached as `deployer`"
      assert_nil store(dir)["agent"], "and NOTHING may land in the agent slot"
    end
  end

  def test_an_explicit_identity_outranks_gh_app_item
    Dir.mktmpdir do |dir|
      env = with_env(dir).merge("GH_APP_ITEM" => "github.mcritchie-deployer")
      _out, err, status = run_token(env, "--identity", "agent")

      assert status.success?, err
      refute_nil store(dir)["agent"], "a caller naming its lane outright still wins"
      assert_nil store(dir)["deployer"]
    end
  end

  def test_no_lane_export_still_defaults_to_the_agent
    Dir.mktmpdir do |dir|
      _out, _err, status = run_token(with_env(dir))

      assert status.success?
      refute_nil store(dir)["agent"]
    end
  end

  # A typo must ABORT. Falling back to `agent` on an unreadable instruction is the
  # precise shape of the original privilege-boundary bug.
  def test_an_unknown_gh_app_item_aborts_instead_of_defaulting_to_agent
    Dir.mktmpdir do |dir|
      env = with_env(dir).merge("GH_APP_ITEM" => "github.mcritchie-typo")
      out, err, status = run_token(env)

      refute status.success?, "an unreadable lane must not silently mint the privileged App"
      assert_match(/github\.mcritchie-typo/, err)
      refute_match(TOKEN_SHAPED, out, "and it must not print a token on the way out")
      refute File.exist?(store_path(dir)), "nothing was minted, so nothing was cached"
    end
  end
end
