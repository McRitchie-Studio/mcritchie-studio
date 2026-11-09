# frozen_string_literal: true

# [unit] bin/lib/heroku_token.rb: where a Heroku token comes from. An override
# the caller set wins; otherwise the lane's 1Password item is read now, with the
# right lane's service-account token and the op cache bypassed; and every way
# the read can fail is a refusal that names the cause, never an empty token.
#
# Run directly:  ruby -Itest test/lib/heroku_token_test.rb
require "minitest/autorun"
require "tmpdir"
require "json"
require "stringio"
require_relative "../support/session_env"
require_relative "../support/fake_heroku_op"
require_relative "../../bin/lib/heroku_token"

class HerokuTokenTest < Minitest::Test
  AGENTS = "HRKU-fake-agents-token-1111111111111111111111111111111111111"
  ADMIN = "HRKU-fake-admin-token-22222222222222222222222222222222222222"
  APPS = "HRKU-fake-applications-token-333333333333333333333333333333"

  def setup
    @dir = Dir.mktmpdir("heroku-token")
    @op = FakeHerokuOp.install(@dir, "studio-agents/heroku.studio.agents" => AGENTS,
                                     "studio-agents-admin/heroku.studio.admin" => ADMIN,
                                     "studio-applications/heroku.studio.applications" => APPS)
    # The cache folder is a tmpdir under the armed sandbox: a soul-set read writes
    # steffon's copy there, never to the operator's real .secret-cache.
    @env = { "OP_SERVICE_ACCOUNT_TOKEN" => "ops_agent", "OP_ADMIN_SERVICE_ACCOUNT_TOKEN" => "ops_admin",
             "MCR_OP_READS_LOG" => File.join(@dir, "op-reads.log"), "CLAUDE_PROJECTS_DIR" => @dir,
             "TASK_USAGE_SANDBOX" => "1", "MCR_SECRET_CACHE_DIR" => nil, "MCR_SOUL_SECRET_SETS" => nil,
             "OP_SERVICE_ACCOUNT_TOKEN_STEFFON" => nil, "MCR_OP_VAULT_AGENT" => nil, "MCR_OP_VAULT_ADMIN" => nil,
             "MCR_OP_VAULT_APPLICATIONS" => nil }
    SoulSecrets::Admin.reset!
    HerokuToken.reset!
  end

  def teardown
    SoulSecrets::Admin.reset!
    HerokuToken.reset!
    FileUtils.rm_rf(@dir)
  end

  # The admin lanes are read only by an admin-tier script: the test reads as
  # bin/heroku-token, which config/soul_secret_sets.yml lists.
  HEROKU_TOKEN_BIN = File.expand_path("../../bin/heroku-token", __dir__)

  def resolve(lane, env: @env, **opts)
    HerokuToken.resolve(lane, env: env, op_bin: @op, program: HEROKU_TOKEN_BIN, **opts)
  end

  def test_each_lane_reads_its_own_item_with_its_own_token_and_no_cache
    assert_equal AGENTS, resolve(:agents)
    assert_equal ADMIN, resolve(:admin)
    assert_equal APPS, resolve("applications")

    calls = FakeHerokuOp.calls(@dir)
    assert_equal [%w[item get heroku.studio.agents --vault studio-agents --format json],
                  %w[read op://studio-agents-admin/heroku.studio.admin/credential],
                  %w[read op://studio-applications/heroku.studio.applications/credential]], calls.map { |c| c["argv"] }
    assert_equal %w[ops_agent ops_admin ops_admin], calls.map { |c| c["token"] },
                 "the admin and applications items are read with the ADMIN service account"
    assert_equal ["false"], calls.map { |c| c["cache"] }.uniq, "every read bypasses the op cache daemon"
  end

  # [unit] secret-silos-phase-two: the agents key is served from steffon's soul
  # set. The first read fills the cache; later reads, in this process or any
  # other, cost no 1Password read.
  def test_the_agents_key_is_read_once_then_served_from_steffons_cache
    3.times { assert_equal AGENTS, resolve(:agents) }
    assert_equal 1, FakeHerokuOp.calls(@dir).size, "one read fills the cache; the rest are cache hits"
    assert File.file?(File.join(@dir, ".secret-cache", "steffon", "item.heroku.studio.agents.json")),
           "the copy is in steffon's folder"
    rows = OpMeter.records(env: @env).map { |r| [r["action"], r["via"]] }
    assert_includes rows, ["cache-hit", "soul:steffon:studio-agents/heroku.studio.agents"]
    refute_includes File.read(File.join(@dir, "op-reads.log")), AGENTS, "the log carries names only"
  end

  # [unit] The admin lanes stay in memory: nothing on disk, one read a process.
  def test_the_admin_lanes_are_never_written_to_disk
    2.times { assert_equal ADMIN, resolve(:admin) }
    assert_equal 1, FakeHerokuOp.calls(@dir).size, "memoized in this process"
    # Every file the tooling wrote (the fake op's own value map is the test's).
    on_disk = Dir.glob(File.join(@dir, "**", "*"), File::FNM_DOTMATCH).select { |f| File.file?(f) } -
              [File.join(@dir, "op-values.json")]
    refute(on_disk.any? { |f| File.read(f).include?(ADMIN) }, "no admin value on disk")
  end

  # [unit] An admin lane read from a script outside the admin tier is refused
  # before any read.
  def test_an_admin_lane_outside_the_admin_tier_is_refused
    error = assert_raises(HerokuToken::Unresolved) do
      HerokuToken.resolve(:admin, env: @env, op_bin: @op, program: __FILE__)
    end
    assert_includes error.message, "not an admin-tier script"
    assert_empty FakeHerokuOp.calls(@dir)
  end

  # [unit] from_env: false reads 1Password fresh (it vouches for the item), and
  # the fresh copy replaces the cached one.
  def test_from_env_false_reads_1password_fresh_and_rewrites_the_cache
    assert_equal AGENTS, resolve(:agents)
    File.write(File.join(@dir, "op-values.json"), JSON.generate("studio-agents/heroku.studio.agents" => "HRKU-rotated"))
    assert_equal "HRKU-rotated", resolve(:agents, from_env: false)
    assert_equal "HRKU-rotated", resolve(:agents), "the cache now holds the fresh copy"
    assert_equal 2, FakeHerokuOp.calls(@dir).size
  end

  # ── with_refresh: Heroku refused the cached key ──────────────────────────

  # A Heroku stand-in: accepts only the key 1Password holds now.
  def heroku_api(token)
    current = JSON.parse(File.read(File.join(@dir, "op-values.json")))["studio-agents/heroku.studio.agents"]
    token == current ? "200" : "401"
  end

  def rotate!(value)
    values = JSON.parse(File.read(File.join(@dir, "op-values.json")))
    File.write(File.join(@dir, "op-values.json"), JSON.generate(values.merge("studio-agents/heroku.studio.agents" => value)))
  end

  def test_with_refresh_a_rotated_key_reads_fresh_once_and_retries
    resolve(:agents)
    rotate!("HRKU-rotated")
    err = StringIO.new
    answer = HerokuToken.with_refresh(:agents, env: @env, op_bin: @op, err: err, rejected: ->(code) { code == "401" }) do |token|
      heroku_api(token)
    end

    assert_equal "200", answer
    assert_equal 2, FakeHerokuOp.calls(@dir).size, "the first fill, then one fresh read"
    assert_match(/heroku refused heroku.studio.agents/, err.string)
    refute_includes err.string, "HRKU-rotated"
  end

  def test_with_refresh_replaces_the_key_export_once_set
    env = @env.dup
    HerokuToken.export_once!(:agents, env: env, op_bin: @op)
    rotate!("HRKU-rotated")
    HerokuToken.with_refresh(:agents, env: env, op_bin: @op, err: StringIO.new, rejected: ->(code) { code == "401" }) do |token|
      heroku_api(token)
    end
    assert_equal "HRKU-rotated", env["HEROKU_API_KEY"], "children now inherit the fresh key"
  end

  def test_with_refresh_clears_an_exported_key_heroku_still_refuses
    env = @env.dup
    HerokuToken.export_once!(:agents, env: env, op_bin: @op)
    assert_raises(AuthRefresh::StillRefused) do
      HerokuToken.with_refresh(:agents, env: env, op_bin: @op, err: StringIO.new, rejected: ->(_c) { true }) { |_t| "401" }
    end
    assert_nil env["HEROKU_API_KEY"], "no child inherits the refused key"
    assert_equal ["still-refused"], OpMeter.records(env: @env).select { |r| r["action"] == "auth-refresh" }.map { |r| r["outcome"] }
  end

  def test_with_refresh_never_replaces_a_key_the_caller_exported
    env = @env.merge("HEROKU_API_KEY" => "HRKU-caller")
    seen = []
    answer = HerokuToken.with_refresh(:agents, env: env, op_bin: @op, rejected: ->(c) { c == "401" }) do |token|
      seen << token
      "401"
    end
    assert_equal "401", answer, "the caller's own key: used once, answer returned"
    assert_equal ["HRKU-caller"], seen
    assert_empty FakeHerokuOp.calls(@dir)
    assert_equal "HRKU-caller", env["HEROKU_API_KEY"]
  end

  # [unit] With no seam, the `op` that answers is the first on PATH, as before;
  # never an absolute path that skips a stub (ecosystem-build's Phase 4 test).
  def test_the_op_is_found_on_path_when_no_seam_names_one
    assert_equal "op", HerokuToken.secret_env({}, nil)["SECRET_OP_BIN"]
    assert_equal "/x/op", HerokuToken.secret_env({ "SECRET_OP_BIN" => "/x/op" }, nil)["SECRET_OP_BIN"]
    assert_equal @op, HerokuToken.secret_env({ "SECRET_OP_BIN" => "/x/op" }, @op)["SECRET_OP_BIN"]
  end

  def test_refusal_matches_herokus_401_wording_only
    assert HerokuToken.refusal?(" !    Invalid credentials provided.")
    assert HerokuToken.refusal?("HTTP Error 401 for GET https://api.heroku.com/apps")
    refute HerokuToken.refusal?(" !    You do not have access to the app mcritchie-studio.")
    refute HerokuToken.refusal?("")
  end

  def test_an_override_the_caller_set_wins_and_reads_nothing
    assert_equal "HRKU-override", resolve(:agents, env: @env.merge("HEROKU_API_KEY" => "HRKU-override"))
    assert_equal "HRKU-admin-override",
                 resolve(:admin, env: @env.merge("HEROKU_STUDIO_ADMIN_API_KEY" => "HRKU-admin-override"))
    assert_empty FakeHerokuOp.calls(@dir)
  end

  def test_from_env_false_ignores_a_stale_export
    stale = @env.merge("HEROKU_API_KEY" => "HRKU-stale-revoked")
    assert_equal AGENTS, resolve(:agents, env: stale, from_env: false)
  end

  def test_a_missing_lane_token_refuses_naming_the_profile_to_source
    error = assert_raises(HerokuToken::Unresolved) { resolve(:admin, env: @env.merge("OP_ADMIN_SERVICE_ACCOUNT_TOKEN" => nil)) }
    assert_includes error.message, "OP_ADMIN_SERVICE_ACCOUNT_TOKEN"
    assert_includes error.message, "source ~/.zprofile.admin"
    assert_empty FakeHerokuOp.calls(@dir), "no read without the token"
  end

  def test_an_empty_or_refused_read_is_a_refusal_not_an_empty_token
    File.write(File.join(@dir, "op-values.json"), "{}")
    error = assert_raises(HerokuToken::Unresolved) { resolve(:agents) }
    assert_includes error.message, "heroku.studio.agents/credential read empty"
  end

  def test_a_missing_op_binary_is_a_refusal
    error = assert_raises(HerokuToken::Unresolved) do
      HerokuToken.resolve(:agents, env: @env, op_bin: File.join(@dir, "no-such-op"))
    end
    assert_includes error.message, "could not start the 1Password CLI"
  end

  def test_a_hung_read_is_killed_at_the_deadline
    File.write(@op, "#!/bin/sh\nsleep 30\n")
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_raises(HerokuToken::Unresolved) { resolve(:agents, env: @env.merge("MCR_OP_DEADLINE" => "0.5")) }
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 10,
                    "the read must be bounded, not wait out the hang"
  end

  def test_export_once_reads_one_time_and_exports_for_every_child
    env = @env.dup
    assert_equal AGENTS, HerokuToken.export_once!(:agents, env: env, op_bin: @op)
    assert_equal AGENTS, env["HEROKU_API_KEY"], "exported for children"
    3.times { HerokuToken.export_once!(:agents, env: env, op_bin: @op) }
    assert_equal 1, FakeHerokuOp.calls(@dir).size, "a second call reads nothing"
  end

  def test_export_once_keeps_a_callers_key
    env = @env.merge("HEROKU_API_KEY" => "HRKU-caller")
    assert_equal "HRKU-caller", HerokuToken.export_once!(:agents, env: env, op_bin: @op)
    assert_empty FakeHerokuOp.calls(@dir)
  end

  def test_shim_on_path_is_true_only_when_the_shim_is_the_first_heroku
    shims = File.expand_path("../../bin/shims", __dir__)
    fake = File.join(@dir, "fakebin")
    FileUtils.mkdir_p(fake)
    File.write(File.join(fake, "heroku"), "#!/bin/sh\n")
    File.chmod(0o755, File.join(fake, "heroku"))

    assert HerokuToken.shim_on_path?("PATH" => "#{shims}:#{fake}")
    refute HerokuToken.shim_on_path?("PATH" => "#{fake}:#{shims}"), "another heroku first brings its own auth"
    refute HerokuToken.shim_on_path?("PATH" => @dir), "no heroku at all"
  end

  def test_an_unknown_lane_is_refused
    assert_raises(HerokuToken::Unresolved) { resolve(:production) }
  end

  def test_profile_names_cover_every_lane_override
    assert_equal %w[HEROKU_API_KEY HEROKU_STUDIO_AGENTS_API_KEY HEROKU_STUDIO_ADMIN_API_KEY
                    HEROKU_STUDIO_APPLICATIONS_API_KEY], HerokuToken::PROFILE_NAMES
  end
end
