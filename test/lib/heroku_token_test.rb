# frozen_string_literal: true

# [unit] bin/lib/heroku_token.rb: where a Heroku token comes from. An override
# the caller set wins; otherwise the lane's 1Password item is read now, with the
# right lane's service-account token and the op cache bypassed; and every way
# the read can fail is a refusal that names the cause, never an empty token.
#
# Run directly:  ruby -Itest test/lib/heroku_token_test.rb
require "minitest/autorun"
require "tmpdir"
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
    @env = { "OP_SERVICE_ACCOUNT_TOKEN" => "ops_agent", "OP_ADMIN_SERVICE_ACCOUNT_TOKEN" => "ops_admin",
             "MCR_OP_READS_LOG" => File.join(@dir, "op-reads.log") }
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def resolve(lane, env: @env, **opts)
    HerokuToken.resolve(lane, env: env, op_bin: @op, **opts)
  end

  def test_each_lane_reads_its_own_item_with_its_own_token_and_no_cache
    assert_equal AGENTS, resolve(:agents)
    assert_equal ADMIN, resolve(:admin)
    assert_equal APPS, resolve("applications")

    calls = FakeHerokuOp.calls(@dir)
    assert_equal %w[op://studio-agents/heroku.studio.agents/credential
                    op://studio-agents-admin/heroku.studio.admin/credential
                    op://studio-applications/heroku.studio.applications/credential], calls.map { |c| c["argv"][1] }
    assert_equal %w[ops_agent ops_admin ops_admin], calls.map { |c| c["token"] },
                 "the admin and applications items are read with the ADMIN service account"
    assert_equal ["false"], calls.map { |c| c["cache"] }.uniq, "every read bypasses the op cache daemon"
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

  def test_an_unknown_lane_is_refused
    assert_raises(HerokuToken::Unresolved) { resolve(:production) }
  end

  def test_profile_names_cover_every_lane_override
    assert_equal %w[HEROKU_API_KEY HEROKU_STUDIO_AGENTS_API_KEY HEROKU_STUDIO_ADMIN_API_KEY
                    HEROKU_STUDIO_APPLICATIONS_API_KEY], HerokuToken::PROFILE_NAMES
  end
end
