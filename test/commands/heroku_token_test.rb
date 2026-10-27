# frozen_string_literal: true

# [unit] bin/heroku-token and bin/shims/heroku as processes, against a fake `op`
# and a fake Heroku CLI. The token reaches the child's ENVIRONMENT only (never
# argv, never output); --check prints a digest prefix, not the value; the shim
# passes a caller's HEROKU_API_KEY straight through and otherwise resolves the
# agents token first.
#
# Run directly:  ruby -Itest test/commands/heroku_token_test.rb
require "minitest/autorun"
require "digest"
require "open3"
require "tmpdir"
require_relative "../support/session_env"
require_relative "../support/fake_heroku_op"

class HerokuTokenCommandTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  BIN = File.join(ROOT, "bin", "heroku-token")
  SHIM = File.join(ROOT, "bin", "shims", "heroku")
  LIVE = "HRKU-live-agents-ffffffffffffffffffffffffffffffffffffffffffffffff"
  ADMIN = "HRKU-live-admin-9999999999999999999999999999999999999999999999"

  def setup
    @dir = Dir.mktmpdir("heroku-token-cli")
    @op_dir = File.join(@dir, "op")
    @op = FakeHerokuOp.install(@op_dir, "studio-agents/heroku.studio.agents" => LIVE,
                                        "studio-agents-admin/heroku.studio.admin" => ADMIN)
    # The fake CLI reports WHICH token it got by digest, plus its argv, so the
    # assertion never needs the value in any output.
    @heroku = File.join(@dir, "bin", "heroku")
    FileUtils.mkdir_p(File.dirname(@heroku))
    File.write(@heroku, <<~RUBY)
      #!/usr/bin/env ruby
      require "digest"
      puts "argv=\#{ARGV.join(' ')}"
      puts "key=\#{Digest::SHA256.hexdigest(ENV['HEROKU_API_KEY'].to_s)[0, 16]}"
    RUBY
    File.chmod(0o755, @heroku)
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def env(extra = {})
    SessionEnv.neutralized(FakeHerokuOp::SCRUB.merge(
      "OP_SERVICE_ACCOUNT_TOKEN" => "ops_fixture_agent",
      "HEROKU_TOKEN_OP_BIN" => @op,
      "MCR_OP_READS_LOG" => File.join(@dir, "op-reads.log"),
      "PATH" => "#{File.dirname(@heroku)}:#{ENV.fetch('PATH')}"
    ).merge(extra))
  end

  def digest(value) = Digest::SHA256.hexdigest(value)[0, 16]

  def run_cmd(*argv, extra: {})
    out, err, status = Open3.capture3(env(extra), *argv)
    [LIVE, ADMIN].each do |secret|
      refute_includes out, secret, "stdout carried a token"
      refute_includes err, secret, "stderr carried a token"
    end
    [out, err, status]
  end

  def test_the_command_gets_the_token_in_its_environment
    out, err, status = run_cmd("ruby", BIN, "agents", "--", @heroku, "config", "--app", "fixture")

    assert status.success?, err
    assert_includes out, "argv=config --app fixture"
    assert_includes out, "key=#{digest(LIVE)}"
  end

  def test_check_prints_a_digest_prefix_and_ignores_an_override
    out, err, status = run_cmd("ruby", BIN, "agents", "--check", extra: { "HEROKU_API_KEY" => "HRKU-stale" })

    assert status.success?, err
    assert_includes out, "agents resolves from heroku.studio.agents"
    assert_includes out, Digest::SHA256.hexdigest(LIVE)[0, 12]
  end

  def test_an_unresolved_lane_runs_nothing
    out, err, status = run_cmd("ruby", BIN, "admin", "--", @heroku, "apps")

    assert_equal 1, status.exitstatus
    assert_includes err, "OP_ADMIN_SERVICE_ACCOUNT_TOKEN"
    assert_includes err, "Nothing was run"
    refute_includes out, "argv="
  end

  def test_usage_errors_exit_2
    assert_equal 2, run_cmd("ruby", BIN, "agents")[2].exitstatus
    assert_equal 2, run_cmd("ruby", BIN, "agents", "--check", "--", "true")[2].exitstatus
    assert_equal 2, run_cmd("ruby", BIN)[2].exitstatus
  end

  def test_the_shim_resolves_the_agents_token_when_none_is_set
    out, err, status = run_cmd(SHIM, "apps", "--all")

    assert status.success?, err
    assert_includes out, "argv=apps --all"
    assert_includes out, "key=#{digest(LIVE)}"
    assert_equal 1, FakeHerokuOp.calls(@op_dir).size
  end

  def test_the_shim_passes_a_callers_key_through_without_a_read
    out, err, status = run_cmd(SHIM, "apps", extra: { "HEROKU_API_KEY" => "HRKU-caller" })

    assert status.success?, err
    assert_includes out, "key=#{digest('HRKU-caller')}"
    assert_empty FakeHerokuOp.calls(@op_dir)
  end

  def test_the_shim_skips_itself_on_path
    shim_dir = File.dirname(SHIM)
    out, err, status = run_cmd(SHIM, "apps", extra: { "PATH" => "#{shim_dir}:#{File.dirname(@heroku)}:/usr/bin:/bin" })

    assert status.success?, err
    assert_includes out, "argv=apps", "the shim must find the real CLI behind itself, not loop"
  end
end
