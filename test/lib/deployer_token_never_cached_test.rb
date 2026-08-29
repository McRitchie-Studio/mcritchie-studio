# frozen_string_literal: true

# [unit] The DEPLOYER token must never be written to, or served from, the cache.
#
# THE DEFECT THIS EXISTS TO CATCH (found 2026-08-28 by Carl, reviewing the
# two-vault split). `bin/gh-token` caches minted tokens in
# `<projects>/.agents/github-tokens.json` so sibling agent PROCESSES can share
# them — correct for `agent`, which re-mints hourly across concurrent lanes.
#
# But the main flow reads that cache BEFORE it mints, and `usable_token` filters
# only on age. So for the 50 minutes after ANY admin-lane mint
# (REFRESH_AFTER_SECONDS = 3000), a deployer token sat in a 0600 file that
# ordinary lanes read by design — and `bin/gh-token --identity deployer`
# SUCCEEDED in a shell carrying no admin token. The two-vault split made a build
# lane unable to MINT admin credentials; it never stopped one OBTAINING a
# deployer token. The docs claimed otherwise.
#
# WHY A SUBPROCESS RATHER THAN UNIT-CALLING THE METHODS. The bug lived in the
# ORDER of the top-level flow — cache read before mint — not in any one method.
# A test that called `usable_token` directly would have passed against the bug.
# These drive the real script with a sandboxed store and a stubbed minter.

require "bundler/setup"
require "minitest/autorun"
require "open3"
require "json"
require "tmpdir"
require "time"
require "fileutils"
require_relative "../support/session_env"

class DeployerTokenNeverCachedTest < Minitest::Test
  BIN = File.expand_path("../../bin/gh-token", __dir__)

  def test_a_deployer_mint_leaves_no_cache_entry
    in_sandbox do |root, store|
      out = run_token(root, "--identity", "deployer")

      assert_includes out, "STUB-TOKEN", "the stubbed mint should have produced a token"
      refute_includes JSON.parse(File.read(store)).keys, "deployer",
                      "a deployer mint must write NO cache entry — a token on disk is " \
                      "readable by every lane for #{'REFRESH_AFTER_SECONDS'} seconds"
    end
  end

  # THE PURGE. An entry written by an earlier version of this script must be
  # DELETED, not merely ignored: ignoring it leaves a live deployer token on disk
  # until it ages out, so the window this change closes would survive the change.
  def test_a_pre_existing_deployer_entry_is_purged
    in_sandbox do |root, store|
      seed = JSON.parse(File.read(store))
      seed["deployer"] = { "active" => "a",
                           "a" => { "token" => "LEFTOVER-FROM-OLD-VERSION",
                                    "created_at" => Time.now.utc.iso8601 } }
      File.write(store, JSON.generate(seed))

      out = run_token(root, "--identity", "deployer")

      refute_includes out, "LEFTOVER-FROM-OLD-VERSION",
                      "a leftover deployer entry must never be SERVED"
      refute_includes JSON.parse(File.read(store)).keys, "deployer",
                      "a leftover deployer entry must be PURGED, not left to age out"
    end
  end

  # THE CONTROL, and it is the half that stops this becoming a regression. The
  # agent identity genuinely needs the cache: agents run as separate processes,
  # so an exported variable is invisible to a sibling. A change that killed
  # caching outright would satisfy every assertion above and break the fleet.
  def test_the_agent_token_is_still_cached
    in_sandbox do |root, store|
      run_token(root)

      entry = JSON.parse(File.read(store))["agent"]

      refute_nil entry, "the agent token must STILL be cached — siblings share it"
      assert_equal "STUB-TOKEN", entry[entry["active"]]["token"]
    end
  end

  def test_a_cached_agent_token_is_served_without_minting
    in_sandbox do |root, store|
      seed = JSON.parse(File.read(store))
      seed["agent"] = { "active" => "a",
                        "a" => { "token" => "CACHED-AGENT", "created_at" => Time.now.utc.iso8601 } }
      File.write(store, JSON.generate(seed))

      assert_includes run_token(root), "CACHED-AGENT",
                      "the agent's cache-first read is the whole reason the cache exists"
    end
  end

  # GUARD THE HARNESS. Every assertion above reads STUB-TOKEN out of the cache or
  # stdout; if the stub were never reached, a mint failure could produce an empty
  # cache and `test_a_deployer_mint_leaves_no_cache_entry` would pass vacuously.
  def test_the_harness_actually_drives_the_script
    in_sandbox do |root, _store|
      assert_includes run_token(root), "STUB-TOKEN",
                      "the agent mint must reach the stubbed minter — without this, an " \
                      "empty cache proves nothing about the deployer"
    end
  end

  private

  def in_sandbox
    Dir.mktmpdir("gh-token-cache") do |root|
      FileUtils.mkdir_p(File.join(root, ".agents"))
      store = File.join(root, ".agents", "github-tokens.json")
      File.write(store, "{}")
      yield root, store
    end
  end

  # The real script, driven through the seams it ACTUALLY honours —
  # CLAUDE_PROJECTS_DIR (bin/gh-token:128), GH_TOKEN_OP_BIN (:126) and
  # GH_TOKEN_MINT_BIN (:127). Nothing here touches 1Password or GitHub.
  #
  # I first wrote this against GH_TOKEN_MINT_STUB and MCR_PROJECTS_ROOT, neither
  # of which exists. A harness built on invented seams fails for the wrong reason
  # or, worse, passes because the script ignored it — so the seams are cited by
  # line above, and `test_the_harness_actually_drives_the_script` proves the stub
  # is reached rather than assumed.
  def run_token(root, *args)
    env = SessionEnv.neutralized(
      "CLAUDE_PROJECTS_DIR" => root,
      "GH_TOKEN_OP_BIN" => stub_bin(root, "op", "echo STUB-VALUE"),
      "GH_TOKEN_MINT_BIN" => stub_bin(root, "mint", "echo STUB-TOKEN")
    )
    out, = Open3.capture2e(env, RbConfig.ruby, BIN, *args)
    out
  end

  def stub_bin(root, name, body)
    path = File.join(root, name)
    File.write(path, "#!/bin/sh\n#{body}\n")
    FileUtils.chmod(0o755, path)
    path
  end
end
