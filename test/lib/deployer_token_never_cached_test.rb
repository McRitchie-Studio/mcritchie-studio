# frozen_string_literal: true

# [unit] The DEPLOYER token must never be written to, or served from, the cache. `bin/gh-token`
# caches minted tokens in `<projects>/.agents/github-tokens.json` for sibling processes, correct
# for `agent`. The main flow reads that cache BEFORE it mints and `usable_token` filters only on
# age.
# WHY A SUBPROCESS: the bug lived in the ORDER of the top-level flow; calling `usable_token`
# directly passes against it. These drive the real script with a sandboxed store and a stubbed
# minter.
# History: task never-cache-deployer-token.

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
      refute_deployer_token_in_secret_cache(root)
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
      refute_deployer_token_in_secret_cache(root)
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

  # The secret cache (<projects>/.secret-cache, 2026-10-27) is where the cache now
  # lives; the legacy store above is the read-through. Neither may hold a deployer
  # token, and no file in the folder may carry one (the manifest names the entry,
  # never a value).
  def refute_deployer_token_in_secret_cache(root)
    home = File.join(root, ".secret-cache")
    tokens = File.join(home, "github-tokens.json")
    refute_includes JSON.parse(File.read(tokens)).keys, "deployer" if File.file?(tokens)
    Dir.glob(File.join(home, "*")).each do |file|
      next if File.symlink?(file)

      text = File.read(file)
      refute_includes text, "STUB-TOKEN\"", "#{File.basename(file)} holds no deployer token" unless file == tokens
      refute_includes text, "LEFTOVER-FROM-OLD-VERSION"
    end
  end

  def in_sandbox
    Dir.mktmpdir("gh-token-cache") do |root|
      FileUtils.mkdir_p(File.join(root, ".agents"))
      store = File.join(root, ".agents", "github-tokens.json")
      File.write(store, "{}")
      yield root, store
    end
  end

  # The real script, driven through the seams it ACTUALLY honours: CLAUDE_PROJECTS_DIR
  # (bin/gh-token#PROJECTS), GH_TOKEN_OP_BIN (bin/gh-token#OP_BIN), GH_TOKEN_MINT_BIN
  # (bin/gh-token#MINT_BIN). Nothing here touches 1Password or GitHub. A harness on invented seams
  # passes because the script ignored it, so `test_the_harness_actually_drives_the_script` proves
  # the stub is reached.
  # History: task never-cache-deployer-token.
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
