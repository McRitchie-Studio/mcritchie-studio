# frozen_string_literal: true

# [unit] config/shared_secret_items.yml and SecretCache.read_ref (task
# secret-silos-phase-two): the Discord webhooks, the R2 backup keys and the
# Google service account are served from the secret cache, and 1Password is read
# only on a miss or an expiry.
#
# Every case runs against a tmpdir cache (CLAUDE_PROJECTS_DIR, sandbox armed), a
# tmpdir read log, and a stub `op` that prints FAKE values and logs its argv
# words only, never its env. Every *_TOKEN leaves ENV for the test, so no child
# inherits a real credential.
#
#   ruby -Itest test/lib/shared_secret_items_test.rb

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "yaml"
require_relative "../../bin/lib/secret_cache"

class SharedSecretItemsTest < Minitest::Test
  REAL_CONFIG = File.expand_path("../../config/shared_secret_items.yml", __dir__)
  SECRET_BIN = File.expand_path("../../bin/secret", __dir__)
  FAKE = "fake-shared-value-not-a-secret"
  WEBHOOK = "op://studio-agents/discord.webhooks/release-notes-webhook"

  def setup
    OpMeter.reset_hang!
    @saved_tokens = ENV.to_h.select { |k, _| k.include?("TOKEN") }
    @saved_tokens.each_key { |k| ENV.delete(k) }
    @root = Dir.mktmpdir("shared-secret-items")
    @op_log = File.join(@root, "op-calls.log")
    @reads_log = File.join(@root, "op-reads.log")
    @op = File.join(@root, "op")
    File.write(@op, "#!/bin/sh\necho \"$1 $2\" >> #{@op_log}\nprintf '%s' '#{FAKE}'\n")
    File.chmod(0o755, @op)
  end

  def teardown
    FileUtils.rm_rf(@root)
    @saved_tokens.each { |k, v| ENV[k] = v }
  end

  def env(extra = {})
    { "CLAUDE_PROJECTS_DIR" => @root, "TASK_USAGE_SANDBOX" => "1", "MCR_SECRET_CACHE_DIR" => nil,
      "MCR_OP_READS_LOG" => @reads_log, "MCR_OP_DEADLINE" => "5", "SECRET_OP_BIN" => @op,
      "MCR_SHARED_SECRET_ITEMS" => nil, "MCR_OP_VAULT_AGENT" => nil, "MCR_OP_VAULT_ADMIN" => nil,
      "OP_SERVICE_ACCOUNT_TOKEN" => nil }.merge(extra)
  end

  def op_calls
    File.exist?(@op_log) ? File.readlines(@op_log) : []
  end

  def refute_leaks(*texts)
    blob = (texts + [File.exist?(@reads_log) ? File.read(@reads_log) : ""]).join("\n")
    refute_includes blob, FAKE, "a value reached output or the read log"
  end

  # ── the config ─────────────────────────────────────────────────────────────

  def test_unit_the_real_config_loads_and_names_no_admin_vault
    entries = SecretCache.shared_item_entries!(env)
    refute_empty entries
    entries.each do |name, meta|
      assert_equal "#{meta['item']}.#{meta['field']}", name, "an entry is named <item>.<field>"
      assert_equal "op-item", meta["kind"]
      refute SecretCache.admin_entry?(meta, env), "#{name} is fed from an admin vault"
      assert_operator meta["lifetime_seconds"], :>, meta["refresh_window_seconds"]
    end
    %w[discord.webhooks r2.mcritchie-agents-backup google.industries.agents gmail.studio.agents].each do |item|
      assert(entries.values.any? { |m| m["item"] == item }, "#{item} is a shared item")
    end
  end

  def test_unit_an_admin_vault_item_is_refused_at_load
    bad = File.join(@root, "bad.yml")
    File.write(bad, YAML.dump("items" => { "x.y" => { "item" => "x", "field" => "y", "lane" => "deployer",
                                                       "lifetime" => "1d" } }))
    error = assert_raises(SecretCache::ConfigError) { SecretCache.shared_item_entries!(env("MCR_SHARED_SECRET_ITEMS" => bad)) }
    assert_match(/admin vault/, error.message)
    assert_empty SecretCache.shared_item_entries(env("MCR_SHARED_SECRET_ITEMS" => bad)), "the lenient read caches nothing"
  end

  # ── read_ref ───────────────────────────────────────────────────────────────

  def test_unit_a_shared_item_is_read_once_then_served_from_the_cache
    e = env
    3.times { assert_equal FAKE, SecretCache.read_ref(WEBHOOK, via: "test", env: e) }

    assert_equal 1, op_calls.size, "one read fills the cache; the rest cost 1Password nothing"
    assert_equal ["read op://studio-agents/discord.webhooks/release-notes-webhook\n"], op_calls
    rows = OpMeter.records(env: e)
    assert_equal 2, rows.count { |r| r["action"] == "cache-hit" }
    assert File.file?(File.join(@root, ".secret-cache", "item.discord.webhooks.release-notes-webhook.json"))
    refute_leaks(rows.to_s)
  end

  def test_unit_an_expired_copy_reads_1password_again
    e = env
    SecretCache.read_ref(WEBHOOK, via: "test", env: e, now: Time.now - (8 * 86_400))
    assert_equal FAKE, SecretCache.read_ref(WEBHOOK, via: "test", env: e)
    assert_equal 2, op_calls.size
  end

  def test_unit_a_ref_no_entry_names_is_read_every_time_and_never_stored
    e = env
    2.times { SecretCache.read_ref("op://studio-agents/x.studio.agents/api-key", via: "test", env: e) }
    assert_equal 2, op_calls.size
    refute(Dir.glob(File.join(@root, ".secret-cache", "item.*")).any?, "nothing stored")
  end

  def test_unit_an_armed_run_with_no_pinned_folder_reads_without_the_cache
    e = env("CLAUDE_PROJECTS_DIR" => nil)
    assert_equal FAKE, SecretCache.read_ref(WEBHOOK, via: "test", env: e.merge("MCR_OP_READS_LOG" => @reads_log))
    assert_equal 1, op_calls.size
    refute File.exist?(File.join(@root, ".secret-cache")), "the operator's folder is never reached from a test"
  end

  def test_unit_a_failed_read_is_nil_and_stores_nothing
    File.write(@op, "#!/bin/sh\necho \"$1 $2\" >> #{@op_log}\nexit 1\n")
    assert_nil SecretCache.read_ref(WEBHOOK, via: "test", env: env)
    refute(Dir.glob(File.join(@root, ".secret-cache", "item.*")).any?)
  end

  def test_unit_a_hung_read_is_killed_at_the_deadline_once
    File.write(@op, "#!/bin/sh\necho \"$1 $2\" >> #{@op_log}\nexec sleep 30\n")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_nil SecretCache.read_ref(WEBHOOK, via: "test", env: env, deadline: 0.5)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 5
    assert_equal 1, op_calls.size, "one attempt: the read already bypasses the op cache"
  end

  # ── bin/secret: the Discord webhooks by hand ───────────────────────────────

  def secret_process(*args, e)
    scrub = ENV.keys.select { |k| k.include?("TOKEN") }.to_h { |k| [k, nil] }
    Open3.capture3(scrub.merge(e).merge("MCR_SOUL" => nil), SECRET_BIN, *args)
  end

  def test_unit_bin_secret_serves_a_discord_webhook_from_the_cache
    e = env
    2.times do
      out, err, status = secret_process("studio-agents", "discord.webhooks", "release-notes-webhook", e)
      assert status.success?, err
      assert_equal FAKE, out
      refute_includes err, FAKE
    end
    assert_equal 1, op_calls.size, "the second read is a cache hit (and no whoami is spent)"
    refute_leaks
  end
end
