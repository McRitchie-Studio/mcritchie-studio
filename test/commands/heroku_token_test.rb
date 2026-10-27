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
  # `#!/usr/bin/env ruby` must find THIS Ruby even when a test narrows PATH.
  RUBY_DIR = File.dirname(RbConfig.ruby)
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
      "PATH" => "#{File.dirname(@heroku)}:#{RUBY_DIR}:#{ENV.fetch('PATH')}",
      # The children are plain scripts: keep the suite's Bundler out of them.
      "BUNDLE_GEMFILE" => nil, "BUNDLE_BIN_PATH" => nil, "RUBYOPT" => nil, "RUBYLIB" => nil
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

  # [unit] What bin/release and bin/qa-server do: export the token once, then make
  # many `heroku` calls. Every call goes through the shim, and 1Password is read
  # ONE time for the whole run, not once per call (Carl, PR 2271: a ship makes
  # dozens to hundreds of `heroku run` calls against a 1000-an-hour quota).
  def test_one_export_serves_many_heroku_calls_with_a_single_read
    script = File.join(@dir, "many_calls.rb")
    File.write(script, <<~RUBY)
      require #{File.join(ROOT, 'bin', 'lib', 'heroku_token').inspect}
      HerokuToken.export_once!(:agents)
      10.times { system(#{SHIM.inspect}, "run", "-a", "fixture", "--", "true", out: File::NULL) || exit(1) }
      system(#{SHIM.inspect}, "whoami")
    RUBY
    out, err, status = run_cmd("ruby", script)

    assert status.success?, err
    assert_includes out, "key=#{digest(LIVE)}", "the children got the exported token"
    assert_equal 1, FakeHerokuOp.calls(@op_dir).size, "eleven heroku calls, one 1Password read"
  end

  # Two shim directories on PATH (the fixed-path tooling and a hub checkout) must
  # not exec each other forever: every copy is skipped by its marker line.
  def test_two_shim_directories_on_path_reach_the_real_cli
    other = File.join(@dir, "other-shims")
    FileUtils.mkdir_p(other)
    FileUtils.cp(SHIM, File.join(other, "heroku"))
    File.chmod(0o755, File.join(other, "heroku"))
    # The copy's own ../heroku-token must resolve too, as it would in a real tree.
    FileUtils.ln_s(BIN, File.join(@dir, "heroku-token"))
    path = "#{other}:#{File.dirname(SHIM)}:#{File.dirname(@heroku)}:#{RUBY_DIR}:/usr/bin:/bin"
    out, err, status = run_cmd(File.join(other, "heroku"), "apps", extra: { "PATH" => path })

    assert status.success?, err
    assert_includes out, "argv=apps"
    assert_includes out, "key=#{digest(LIVE)}"
  end

  def test_shims_alone_on_path_refuse_instead_of_looping
    other = File.join(@dir, "other-shims")
    FileUtils.mkdir_p(other)
    FileUtils.cp(SHIM, File.join(other, "heroku"))
    File.chmod(0o755, File.join(other, "heroku"))
    path = "#{other}:#{File.dirname(SHIM)}:#{RUBY_DIR}:/usr/bin:/bin"
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    _out, err, status = run_cmd(SHIM, "apps", extra: { "PATH" => path, "HEROKU_API_KEY" => "HRKU-caller" })

    assert_equal 127, status.exitstatus, err
    assert_includes err, "no Heroku CLI on PATH besides heroku-token shims"
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 10
  end

  def test_the_shim_skips_itself_on_path
    shim_dir = File.dirname(SHIM)
    out, err, status = run_cmd(SHIM, "apps", extra: { "PATH" => "#{shim_dir}:#{File.dirname(@heroku)}:#{RUBY_DIR}:/usr/bin:/bin" })

    assert status.success?, err
    assert_includes out, "argv=apps", "the shim must find the real CLI behind itself, not loop"
  end
end
