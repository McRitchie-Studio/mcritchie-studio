# frozen_string_literal: true

# [integration] bin/secret — the one read path over the secret cache, driven as a
# process through bin/gh-token with stub `op` and stub minter binaries. No real
# 1Password read, no real mint, no real token, and never the operator's real
# <projects>/.secret-cache (CLAUDE_PROJECTS_DIR is a tmpdir and the sandbox is armed).
#
#   ruby -Itest test/commands/secret_cli_test.rb

require "minitest/autorun"
require "json"
require "open3"
require "tmpdir"
require "fileutils"
require "time"

class SecretCliTest < Minitest::Test
  BIN = File.expand_path("../../bin/secret", __dir__)
  OLD = "ghs_OLDCACHEDVALUE0000000000"
  NEW = "ghs_FRESHMINTEDVALUE111111111"
  TOKEN_SHAPED = /gh[psou]_[A-Za-z0-9_.-]{8,}/

  def setup
    @root = Dir.mktmpdir("secret-cli")
    @home = File.join(@root, ".secret-cache")
    @op_log = File.join(@root, "op-calls.log")
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def stub(name, body)
    path = File.join(@root, name)
    File.write(path, "#!/bin/sh\n#{body}\n")
    File.chmod(0o755, path)
    path
  end

  def env(op_body: "echo stub-app-secret", extra: {})
    {
      "CLAUDE_PROJECTS_DIR" => @root,
      "TASK_USAGE_SANDBOX" => "1",
      "GH_TOKEN_OP_BIN" => stub("op", "echo \"$@\" >> #{@op_log}\n#{op_body}"),
      "GH_TOKEN_MINT_BIN" => stub("mint", "echo #{NEW}"),
      "MCR_OP_READS_LOG" => File.join(@root, "op-reads.log"),
      "GH_APP_ITEM" => nil,
      "MCR_SECRET_CACHE_DIR" => nil,
      "OP_ADMIN_SERVICE_ACCOUNT_TOKEN" => nil
    }.merge(extra)
  end

  def secret(*args, env: self.env)
    Open3.capture3(env, BIN, *args)
  end

  def seed(age_seconds, token: OLD)
    FileUtils.mkdir_p(@home, mode: 0o700)
    File.chmod(0o700, @home)
    path = File.join(@home, "github-tokens.json")
    File.write(path, JSON.generate("agent" => { "active" => "a",
                                                "a" => { "token" => token,
                                                         "created_at" => (Time.now.utc - age_seconds).iso8601 } }),
               perm: 0o600)
  end

  def op_calls
    File.exist?(@op_log) ? File.read(@op_log).lines.size : 0
  end

  # The control for every refute_match on TOKEN_SHAPED below.
  def test_the_leak_detector_matches_the_values_this_file_issues
    assert_match TOKEN_SHAPED, OLD
    assert_match TOKEN_SHAPED, NEW
    refute_match TOKEN_SHAPED, "github.agent: expires in 42 min"
  end

  # ── the cache answers first ────────────────────────────────────────────────

  def test_integration_a_fresh_token_is_served_from_the_cache_without_1password
    seed(5 * 60)
    out, err, status = secret("get", "github.agent")

    assert status.success?, err
    assert_equal OLD, out.strip
    assert_equal 0, op_calls, "a fresh cached token costs no 1Password read"
  end

  def test_integration_a_read_inside_the_refresh_window_refreshes_and_returns_the_fresh_value
    seed(52 * 60) # 8 minutes left: inside GitHub's last-10-minute window
    out, err, status = secret("get", "github.agent")

    assert status.success?, err
    assert_equal NEW, out.strip
    assert_operator op_calls, :>, 0, "the window read went to 1Password"
    out2, = secret("get", "github.agent")
    assert_equal NEW, out2.strip, "the fresh value was written back"
  end

  def test_integration_a_read_after_expiry_refreshes
    seed(70 * 60)
    out, err, status = secret("get", "github.agent")

    assert status.success?, err
    assert_equal NEW, out.strip
  end

  # ── 1Password hangs ────────────────────────────────────────────────────────

  def test_integration_op_hanging_falls_to_the_contingency_within_seconds
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    out, err, status = secret("get", "github.agent",
                              env: env(op_body: "sleep 30", extra: { "MCR_OP_DEADLINE" => "1" }))
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    refute status.success?
    assert_operator elapsed, :<, 10, "a hung op must not hold the caller (took #{elapsed.round(1)} s)"
    assert_equal "", out, "no value on stdout when nothing could be read"
    assert_includes err, "contingency for github.agent"
    assert_includes err, "token-session"
    assert_includes err, "quit and reopen the 1Password app"
    assert_includes err, "blocker"
    status_out, = secret("status")
    assert_includes status_out, "last refresh FAILED"
  end

  def test_integration_op_hanging_with_a_still_valid_token_serves_it_with_a_warning
    seed(55 * 60) # in the window, five minutes of life left
    out, err, status = secret("get", "github.agent",
                              env: env(op_body: "sleep 30", extra: { "MCR_OP_DEADLINE" => "1" }))

    assert status.success?, err
    assert_equal OLD, out.strip, "a token that still works beats no token"
    assert_includes err, "refresh failed"
    refute_match TOKEN_SHAPED, err
  end

  # The 2026-10-27 report: refresh said "refreshed" right after gh-token served
  # the cached token because 1Password was unreadable.
  def test_integration_refresh_and_prewarm_with_a_hung_op_say_served_cached_fallback
    seed(55 * 60)
    hung = env(op_body: "sleep 30", extra: { "MCR_OP_DEADLINE" => "1", "SECRET_PREWARM_IN_SANDBOX" => "1" })

    out, err, status = secret("refresh", "github.agent", env: hung)
    refute status.success?, "a refresh that served the old token is not a success"
    assert_includes out, "github.agent: served cached fallback"
    refute_includes out, "refreshed"
    refute_match TOKEN_SHAPED, out + err

    out, err, status = secret("prewarm", env: hung)
    assert status.success?, "prewarm never fails the run: #{err}"
    assert_includes out, "github.agent: served cached fallback"
    refute_includes out, "refreshed"
  end

  def test_integration_forget_harness_key_honours_mcr_secret_cache_dir
    pinned = File.join(@root, "pinned-cache")
    FileUtils.mkdir_p(pinned, mode: 0o700)
    File.chmod(0o700, pinned)
    key = File.join(pinned, "harness-key.json")
    File.write(key, JSON.generate("token" => "HARNESSVALUE"), perm: 0o600)
    only_pinned = env(extra: { "MCR_SECRET_CACHE_DIR" => pinned, "CLAUDE_PROJECTS_DIR" => nil })

    out, err, status = secret("forget", "harness-key", env: only_pinned)
    assert status.success?, err
    assert_includes out, "harness-key: forgotten"
    refute File.exist?(key)
  end

  # ── forget, refresh, status ────────────────────────────────────────────────

  def test_integration_forget_clears_the_entry_and_the_next_read_fetches_fresh
    seed(5 * 60)
    out, err, status = secret("forget", "github.agent")

    assert status.success?, err
    assert_includes out, "github.agent: forgotten"
    status_out, = secret("status")
    assert_includes status_out, "github.agent: not cached"
    fresh, = secret("get", "github.agent")
    assert_equal NEW, fresh.strip
  end

  def test_integration_forget_by_source_item_clears_every_entry_it_feeds
    seed(5 * 60)
    out, _err, status = secret("forget", "--source", "github.mcritchie-agent")

    assert status.success?
    assert_includes out, "github.agent: forgotten"
    refute_includes out, "github.deployer", "an item feeds only its own entries"
  end

  def test_integration_refresh_if_under_leaves_a_fresh_token_alone
    seed(5 * 60)
    out, _err, status = secret("refresh", "github.agent", "--if-under", "45")

    assert status.success?
    assert_includes out, "fresh enough"
    assert_equal 0, op_calls
  end

  def test_integration_no_value_ever_appears_in_metadata_output_or_files
    seed(5 * 60)
    outputs = [
      secret("status"), secret("contingency", "github.agent"), secret("migrate"),
      secret("refresh", "github.agent"), secret("status"), secret("forget", "github.agent")
    ].flat_map { |o, e, _s| [o, e] }
    files = %w[README.md manifest.json].map { |f| File.read(File.join(@home, f)) }

    (outputs + files).each { |text| refute_match TOKEN_SHAPED, text }
    assert_includes outputs.join, "expires in", "the detector ran over real status output"
  end

  def test_integration_a_widened_folder_fails_loudly
    seed(5 * 60)
    File.chmod(0o755, @home)
    _out, err, status = secret("status")

    refute status.success?
    assert_includes err, "chmod 700"
    _out, err2, status2 = secret("get", "github.agent")
    refute status2.success?, "a token in a widened folder is never served"
    assert_includes err2, "wider than 0700"
  end

  # ── migration of the legacy caches ─────────────────────────────────────────

  def test_integration_migrate_adopts_both_legacy_caches_and_old_paths_still_read
    agents = File.join(@root, ".agents")
    FileUtils.mkdir_p(agents)
    File.write(File.join(agents, "github-tokens.json"),
               JSON.generate("agent" => { "active" => "a",
                                          "a" => { "token" => OLD, "created_at" => Time.now.utc.iso8601 } }),
               perm: 0o600)
    File.write(File.join(agents, "harness-key.json"), JSON.generate("token" => "HKEY"), perm: 0o600)

    _out, err, status = secret("migrate")

    assert status.success?, err
    %w[github-tokens.json harness-key.json].each do |file|
      legacy = File.join(agents, file)
      assert File.symlink?(legacy), "#{file}: old path is a link"
      assert_equal File.join(@home, file), File.readlink(legacy)
      assert_equal 0o600, File.stat(File.join(@home, file)).mode & 0o777
    end
    out, = secret("get", "github.agent")
    assert_equal OLD, out.strip, "the migrated session is served without a mint"
    assert_equal 0, op_calls
  end

  # ── the classic read names its item ────────────────────────────────────────

  def test_integration_the_classic_read_records_which_item_in_the_read_log
    op = stub("op-classic", "echo THE-VALUE")
    out, err, status = secret("studio-agents", "agent.heroku", "api key",
                              env: env(extra: { "SECRET_OP_BIN" => op }))

    assert status.success?, err
    assert_equal "THE-VALUE", out
    log = File.read(File.join(@root, "op-reads.log"))
    assert_includes log, "secret:studio-agents/agent.heroku"
    refute_includes log, "THE-VALUE"
  end

  def test_integration_a_manifest_op_item_is_served_from_the_cache_on_the_second_read
    seed(5 * 60)
    secret("status") # lays down the manifest
    secret("migrate")
    manifest_path = File.join(@home, "manifest.json")
    manifest = JSON.parse(File.read(manifest_path))
    manifest["entries"]["agent.heroku"] = { "kind" => "op-item", "vault" => "studio-agents",
                                            "item" => "agent.heroku", "field" => "api key",
                                            "lifetime_seconds" => 3600, "refresh_window_seconds" => 600 }
    File.write(manifest_path, JSON.generate(manifest))
    counter = File.join(@root, "classic-calls.log")
    op = stub("op-counted", "echo x >> #{counter}\necho THE-VALUE")
    classic_env = env(extra: { "SECRET_OP_BIN" => op })

    first, = secret("studio-agents", "agent.heroku", "api key", env: classic_env)
    second, = secret("studio-agents", "agent.heroku", "api key", env: classic_env)
    status_out, = secret("status", env: classic_env)

    assert_equal %w[THE-VALUE THE-VALUE], [first, second]
    assert_equal 1, File.read(counter).lines.size, "the second read came from the cache"
    assert_includes File.read(File.join(@root, "op-reads.log")), "cache-hit", "the hit is logged for the data pass"
    assert_includes status_out, "agent.heroku: expires in"
    refute_includes status_out, "THE-VALUE"
  end
end
