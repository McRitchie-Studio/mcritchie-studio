# frozen_string_literal: true

# [unit] bin/agent-worktree starts a desk server under an ALLOW-LISTED environment.
#
# WHY (secrets-never-on-argv-or-desk-env, 2026-10-24). Desk servers inherited the
# agent shell's whole environment. Puma and Sidekiq rename their process titles,
# and on macOS `pgrep -fl` then prints a renamed process's environment, so one
# listing put HEROKU_API_KEY into a transcript and the key was rotated.
#
# HOW. A clean ruby subprocess `load`s the real bin/agent-worktree (its dispatch is
# guarded, so no subcommand runs), plants fake credentials in its own ENV, and
# calls the real `spawn_desk_server` with a stub "server" that writes its
# environment to a file and exits. The assertions read that file: the forbidden
# names are absent, the system names and the desk's values are present.
#
# THE CONTROL. The same subprocess, with ChildEnv.desk_server replaced by the
# pre-fix behaviour (the parent's whole ENV, merged), must hand the stub the
# credentials. Without it, "the stub saw no secret" and "the fixture never planted
# one" are the same observation.
#
# Run directly:  ruby -Itest test/lib/desk_server_env_test.rb
require "minitest/autorun"
require "open3"
require "tmpdir"
require_relative "../support/session_env"
require_relative "../../bin/lib/child_env"

class DeskServerEnvTest < Minitest::Test
  BIN = File.expand_path("../../bin/agent-worktree", __dir__)

  # Each fake value is unique so a hit names its source.
  PLANTED = {
    "HEROKU_API_KEY" => "fake-heroku-key",
    "OP_SERVICE_ACCOUNT_TOKEN" => "fake-op-token",
    "OP_ADMIN_SERVICE_ACCOUNT_TOKEN" => "fake-op-admin-token",
    "AGENT_API_SECRET" => "fake-agent-secret",
    "AGENT_API_TOKEN" => "fake-agent-token",
    "GH_TOKEN" => "fake-gh-token",
    "GITHUB_TOKEN" => "fake-github-token",
    "CLAUDE_CODE_MESSAGING_TOKEN" => "fake-claude-messaging",
    "ANTHROPIC_API_KEY" => "fake-anthropic-key",
    "SOME_FUTURE_SECRET" => "fake-unlisted-name"
  }.freeze

  # The desk's own stack values, passed explicitly by the launcher. HEROKU_API_KEY
  # here proves the forbidden fence holds even over an explicit value.
  DESK_VALUES = {
    "APP_PORT" => "3999", "PORT" => "3999",
    "DATABASE_URL" => "postgres://localhost/desk_fixture",
    "REDIS_URL" => "redis://localhost:6379/9",
    "LOCAL_EMAIL_CAPTURE" => "1",
    "HEROKU_API_KEY" => "fake-heroku-key-from-stack"
  }.freeze

  def launch(prelude: "")
    Dir.mktmpdir("desk-server-env") do |dir|
      dump = File.join(dir, "env.out")
      log = File.join(dir, "server.log")
      script = <<~RUBY
        load #{BIN.inspect}
        #{prelude}
        pid = spawn_desk_server(#{DESK_VALUES.inspect}, ["/bin/sh", "-c", "env > #{dump}"],
                                chdir: #{dir.inspect}, logfile: #{log.inspect})
        60.times { break if File.size?(#{dump.inspect}); sleep 0.1 }
        puts pid
      RUBY
      env = SessionEnv.neutralized(PLANTED.merge("LANG" => "en_US.UTF-8", "BINDING" => "0.0.0.0",
                                                  "ENABLE_FIAT_RAILS" => "true"))
      out, err, status = Open3.capture3(env, "ruby", "-e", script)
      assert status.success?, "the launcher subprocess failed:\n#{out}\n#{err}"
      assert File.size?(dump), "the stub server never wrote its environment (#{err})"
      File.readlines(dump, chomp: true).to_h { |line| line.split("=", 2) }
    end
  end

  def test_the_desk_server_sees_no_credential_and_keeps_what_it_needs
    seen = launch

    PLANTED.each_key { |name| refute seen.key?(name), "#{name} reached the desk server" }
    refute(seen.values.any? { |v| v.start_with?("fake-") }, "a planted value reached the desk server (names: #{seen.keys.sort.inspect})")
    %w[PATH HOME LANG].each { |name| assert seen.key?(name), "#{name} is missing from the desk server" }
    assert_equal "0.0.0.0", seen["BINDING"], "BINDING (bin/agent-worktree up's LAN mode) must reach the server"
    assert_equal "true", seen["ENABLE_FIAT_RAILS"], "an ENABLE_* boot flag must reach the server"
    (DESK_VALUES.keys - ["HEROKU_API_KEY"]).each do |name|
      assert_equal DESK_VALUES[name], seen[name], "the desk value #{name} did not reach the server"
    end
    allowed = ChildEnv::SYSTEM_ALLOW + ChildEnv::DESK_SERVER_ALLOW + DESK_VALUES.keys + ["ENABLE_FIAT_RAILS"]
    extra = seen.keys - allowed - %w[PWD SHLVL _ OLDPWD]
    # ENABLE_* boot flags pass by prefix, and CI's runner exports its own (ENABLE_RUNNER_TRACING).
    extra.reject! { |name| ChildEnv::DESK_SERVER_ALLOW_PREFIXES.any? { |prefix| name.start_with?(prefix) } }
    assert_empty extra, "names outside the allow-list reached the desk server: #{extra.inspect}"
  end

  def test_control_without_the_scrub_the_stub_sees_the_secrets
    seen = launch(prelude: <<~RUBY)
      def ChildEnv.desk_server(values, env = ENV) = env.to_h.merge(values)
    RUBY

    assert_equal "fake-heroku-key-from-stack", seen["HEROKU_API_KEY"],
                 "the control saw no HEROKU_API_KEY, so the fixture never reached the child and the scrub test proves nothing"
    assert_equal "fake-op-token", seen["OP_SERVICE_ACCOUNT_TOKEN"]
    assert_equal "fake-unlisted-name", seen["SOME_FUTURE_SECRET"]
  end

  def test_forbidden_names_cover_the_incident_list
    %w[HEROKU_API_KEY OP_SERVICE_ACCOUNT_TOKEN OP_ADMIN_SERVICE_ACCOUNT_TOKEN AGENT_API_SECRET AGENT_API_TOKEN
       GH_TOKEN GITHUB_TOKEN CLAUDE_CODE_MESSAGING_TOKEN ANTHROPIC_API_KEY].each do |name|
      assert ChildEnv.forbidden?(name), "#{name} is not forbidden"
    end
    refute ChildEnv.forbidden?("DATABASE_URL")
  end
end
