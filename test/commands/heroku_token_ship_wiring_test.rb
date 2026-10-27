# frozen_string_literal: true

# [unit] bin/release (at its first PROD board op) and bin/qa-server resolve the Heroku token ONCE, before
# their first `heroku` call, and refuse cleanly when it cannot be resolved: no
# heroku call is made and nothing is written. The single-read property itself is
# proven in test/commands/heroku_token_test.rb (one export, many calls, one read).
#
# Run directly:  ruby -Itest test/commands/heroku_token_ship_wiring_test.rb
require "minitest/autorun"
require "open3"
require "tmpdir"
require_relative "../support/session_env"
require_relative "../support/fake_heroku_op"

class HerokuTokenShipWiringTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def setup
    @dir = Dir.mktmpdir("heroku-token-ship")
    @heroku = File.join(@dir, "heroku")
    File.write(@heroku, "#!/bin/sh\necho \"$*\" >> #{File.join(@dir, 'heroku.log')}\n")
    File.chmod(0o755, @heroku)
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  SHIMS = File.join(ROOT, "bin", "shims")

  # +shim+: put bin/shims first on PATH, as ~/.zprofile does after the migration.
  def run_script(*argv, shim: true)
    path = [(SHIMS if shim), @dir, File.dirname(RbConfig.ruby), ENV.fetch("PATH")].compact.join(":")
    env = SessionEnv.neutralized(FakeHerokuOp::SCRUB.merge(
      "PATH" => path,
      "HEROKU_TOKEN_OP_BIN" => File.join(@dir, "no-such-op"),
      "MCR_OP_READS_LOG" => File.join(@dir, "op-reads.log"),
      "BUNDLE_GEMFILE" => nil, "BUNDLE_BIN_PATH" => nil, "RUBYOPT" => nil, "RUBYLIB" => nil
    ))
    Open3.capture3(env, "ruby", *argv, chdir: ROOT)
  end

  def heroku_calls
    path = File.join(@dir, "heroku.log")
    File.exist?(path) ? File.read(path) : ""
  end

  def test_release_refuses_before_any_heroku_call_without_a_token
    _out, err, status = run_script(File.join(ROOT, "bin", "release.rb"), "status")

    refute status.success?
    assert_includes err, "no Heroku token for the PROD board"
    assert_includes err, "Nothing was done"
    assert_empty heroku_calls, "no `heroku run` may start before the token is resolved"
  end

  def test_qa_server_refuses_before_any_heroku_call_without_a_token
    _out, err, status = run_script(File.join(ROOT, "bin", "qa-server"), "status", "turf-monster")

    refute status.success?
    assert_includes err, "qa-server: no Heroku token"
    assert_empty heroku_calls
  end

  # A `heroku` that is not the shim (the real CLI with its own login, a test's
  # fake) never reads 1Password, so bin/release neither resolves nor refuses.
  def test_without_the_shim_on_path_release_neither_reads_nor_refuses
    _out, err, _status = run_script(File.join(ROOT, "bin", "release.rb"), "status", shim: false)

    refute_includes err, "no Heroku token"
    refute_empty heroku_calls, "the run went on to its own heroku"
  end

  def test_release_resolves_after_the_argument_guard_so_help_reads_nothing
    out, err, _status = run_script(File.join(ROOT, "bin", "release.rb"), "status", "--help")

    assert_includes out + err, "usage: bin/release status"
    refute_includes err, "no Heroku token", "help is answered before the token is resolved"
    assert_empty heroku_calls
  end
end
