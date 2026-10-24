# frozen_string_literal: true

# [unit] Every hub launcher starts its children under ChildEnv's allow-list.
#
# WHY (secrets-scrub-follow-ups, 2026-10-24). secrets-never-on-argv-or-desk-env
# scrubbed the desk servers bin/agent-worktree starts; review found the other
# launchers still handed their children the agent shell's whole environment:
# bin/dev (foreman, Puma), bin/ecosystem-build's Phase 8 (the primaries' Puma,
# after the script has sourced ~/.zprofile), LaneRunner (fast-check's suites,
# whose parallel workers rename their titles), and the three detached lease
# renewers (bin/devops-shift, review_claim_cli, release_claim_cli), which live as
# long as a lease. On macOS `ps` and `pgrep -fl` print a renamed process's
# environment, and that is how HEROKU_API_KEY reached a transcript.
#
# HOW. Each launcher's REAL spawn site runs in a clean subprocess with fake
# credentials planted, and starts a stub child that writes its environment to a
# file and exits. The subprocess itself starts from a minimal environment
# (unsetenv_others), so the operator's real credentials never enter this test.
#
# THE CONTROL. Each launcher is run again with its scrub replaced by the pre-fix
# behaviour (the parent's whole environment), and the stub must then SEE the
# planted credentials. Without it, "the child saw no secret" and "the fixture
# never planted one" are the same observation.
#
# Run directly:  ruby -Itest test/lib/launcher_child_env_test.rb
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"
require_relative "../../bin/lib/child_env"

class LauncherChildEnvTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  CHILD_ENV = File.join(ROOT, "bin/lib/child_env.rb")

  PLANTED = {
    "HEROKU_API_KEY" => "fake-heroku-key",
    "OP_SERVICE_ACCOUNT_TOKEN" => "fake-op-token",
    "AGENT_API_SECRET" => "fake-agent-secret",
    "GH_TOKEN" => "fake-gh-token",
    "CLAUDE_CODE_MESSAGING_TOKEN" => "fake-claude-messaging",
    "ANTHROPIC_API_KEY" => "fake-anthropic-key",
    "SOME_FUTURE_SECRET" => "fake-unlisted-secret",
    "RAILS_MASTER_KEY" => "fake-master-key"
  }.freeze

  # What every child keeps: the login basics and the whole locale family.
  KEPT = { "LANG" => "en_US.UTF-8", "LC_MESSAGES" => "en_US.UTF-8" }.freeze

  # The minimal parent environment: enough to find ruby, bash and the stubs.
  def base_env(extra = {})
    path = [extra.delete("STUB_PATH"), RbConfig::CONFIG["bindir"], "/usr/bin", "/bin"].compact.join(":")
    { "PATH" => path, "HOME" => Dir.home }.merge(KEPT).merge(PLANTED).merge(extra)
  end

  def read_env(dump)
    80.times { break if File.size?(dump); sleep 0.05 }
    assert File.size?(dump), "the stub child never wrote its environment"
    File.readlines(dump, chomp: true).filter_map { |l| l.split("=", 2) if l.include?("=") }.to_h
  end

  def run_ruby(script, env)
    out, status = Open3.capture2e(base_env(env), RbConfig.ruby, "-e", script, unsetenv_others: true)
    assert status.success?, "the launcher subprocess failed:\n#{out}"
  end

  def assert_scrubbed(seen, where)
    PLANTED.each_key { |name| refute seen.key?(name), "#{name} reached the child (#{where})" }
    refute(seen.values.any? { |v| v.start_with?("fake-") }, "a planted value reached the child (#{where}): #{seen.keys.sort}")
    %w[PATH HOME].each { |name| assert seen.key?(name), "#{name} is missing (#{where})" }
    KEPT.each { |name, value| assert_equal value, seen[name], "#{name} did not reach the child (#{where})" }
  end

  def assert_control_leaks(seen, where)
    assert_equal "fake-heroku-key", seen["HEROKU_API_KEY"],
                 "the control saw no HEROKU_API_KEY (#{where}), so the scrub test proves nothing"
    assert_equal "fake-unlisted-secret", seen["SOME_FUTURE_SECRET"]
  end

  # ---------------------------------------------------------------- renewers --

  RENEWERS = {
    "bin/devops-shift" => ["DevopsShiftCli", "DEVOPS_SHIFT"],
    "bin/lib/review_claim_cli.rb" => ["ReviewClaimCli", "TASK_REVIEW_CLAIM"],
    "bin/lib/release_claim_cli.rb" => ["ReleaseClaimCli", "RELEASE_CONDUCTOR_CLAIM"]
  }.freeze

  def launch_renewer(file, klass, prefix, prelude: "")
    Dir.mktmpdir("renewer-env") do |dir|
      dump = File.join(dir, "env.out")
      script = <<~RUBY
        load #{File.join(ROOT, file).inspect}
        #{prelude}
        cli = #{klass}.new(env: ENV)
        cli.send(:spawn_detached, { "#{prefix}_SESSION" => "sess-1", "TASK_CLAIM_NONCE" => "nonce-1" },
                 ["/bin/sh", "-c", "env > #{dump}"])
      RUBY
      run_ruby(script, "ATOMIC_CAPTURE_URL" => "http://127.0.0.1:9", "CLAUDE_PROJECTS_DIR" => dir,
                       "#{prefix}_RENEW_INTERVAL" => "7")
      read_env(dump)
    end
  end

  def test_each_renewer_starts_with_its_identity_and_no_credential
    RENEWERS.each do |file, (klass, prefix)|
      seen = launch_renewer(file, klass, prefix)

      assert_scrubbed(seen, file)
      assert_equal "sess-1", seen["#{prefix}_SESSION"], "#{file}: the renewer lost its session"
      assert_equal "nonce-1", seen["TASK_CLAIM_NONCE"], "#{file}: the renewer lost its nonce"
      assert_equal "http://127.0.0.1:9", seen["ATOMIC_CAPTURE_URL"], "#{file}: the renewer lost the board URL"
      assert seen.key?("CLAUDE_PROJECTS_DIR"), "#{file}: the renewer lost the token cache's directory"
      assert_equal "7", seen["#{prefix}_RENEW_INTERVAL"], "#{file}: the renewer lost its interval"
    end
  end

  def test_control_each_renewer_without_the_scrub_leaks
    RENEWERS.each do |file, (klass, prefix)|
      seen = launch_renewer(file, klass, prefix, prelude: <<~RUBY)
        def ChildEnv.renewer(values, env = ENV, allow: []) = env.to_h.merge(values)
      RUBY
      assert_control_leaks(seen, file)
    end
  end

  # ------------------------------------------------------------- LaneRunner --

  def launch_lane(prelude: "")
    Dir.mktmpdir("lane-env") do |dir|
      dump = File.join(dir, "env.out")
      script = <<~RUBY
        require #{File.join(ROOT, "bin/lib/lane_runner").inspect}
        #{prelude}
        r = LaneRunner.run({ "RAILS_ENV" => "test" }, "env > #{dump}", chdir: #{dir.inspect}, timeout: 30)
        exit(r.ok ? 0 : 1)
      RUBY
      run_ruby(script, "PARALLEL_WORKERS" => "1", "STUB_LOG" => "/tmp/x", "SSH_AUTH_SOCK" => "/tmp/agent.sock",
                       "PGPASSWORD" => "fake-pg-password", "NPM_TOKEN" => "fake-npm-token")
      read_env(dump)
    end
  end

  def test_a_lane_keeps_its_knobs_and_drops_every_credential
    seen = launch_lane

    assert_scrubbed(seen, "LaneRunner")
    %w[PGPASSWORD NPM_TOKEN].each { |name| refute seen.key?(name), "#{name} reached the lane" }
    assert_equal "test", seen["RAILS_ENV"], "the caller's lane value must reach the lane"
    assert_equal "1", seen["PARALLEL_WORKERS"], "an operator's one-run knob must reach the lane"
    assert_equal "/tmp/x", seen["STUB_LOG"], "a test stub's own variable must reach the lane"
    assert_equal "/tmp/agent.sock", seen["SSH_AUTH_SOCK"], "SSH_AUTH_SOCK is listed, so it survives the pattern"
  end

  def test_control_a_lane_without_the_scrub_leaks
    seen = launch_lane(prelude: "def ChildEnv.lane(values, env = ENV) = env.to_h.merge(values)")
    assert_control_leaks(seen, "LaneRunner")
  end

  # ---------------------------------------------- shell launchers (CLI exec) --

  # A copy of bin/lib/child_env.rb's CLI whose desk_server is the pre-fix merge,
  # for the shell launchers' control runs.
  def control_child_env(dir)
    lib = File.join(dir, "lib")
    FileUtils.mkdir_p(lib)
    File.write(File.join(lib, "child_env.rb"), <<~RUBY)
      require #{CHILD_ENV.inspect}
      def ChildEnv.desk_server(values, env = ENV) = env.to_h.merge(values)
      ChildEnv.exec_cli(ARGV.dup)
    RUBY
    dir
  end

  def stub(dir, name, body)
    path = File.join(dir, name)
    File.write(path, "#!/bin/sh\n#{body}\n")
    File.chmod(0o755, path)
  end

  def launch_bin_dev(control: false)
    Dir.mktmpdir("bin-dev-env") do |dir|
      dump = File.join(dir, "env.out")
      stubs = File.join(dir, "stubs")
      FileUtils.mkdir_p(stubs)
      stub(stubs, "gem", "exit 0") # `gem list foreman -i` answers installed; nothing is installed
      stub(stubs, "foreman", "env > #{dump}")
      dev = File.join(ROOT, "bin/dev")
      if control
        bin = control_child_env(File.join(dir, "bin"))
        FileUtils.cp(dev, File.join(bin, "dev"))
        dev = File.join(bin, "dev")
      end
      out, status = Open3.capture2e(base_env("STUB_PATH" => stubs), "sh", dev, unsetenv_others: true, chdir: dir)
      assert status.success?, "bin/dev failed:\n#{out}"
      read_env(dump)
    end
  end

  def test_bin_dev_starts_foreman_under_the_allow_list
    seen = launch_bin_dev

    assert_scrubbed(seen, "bin/dev")
    assert_equal "3000", seen["PORT"], "bin/dev's own PORT default must reach foreman"
    assert_equal "true", seen["RUBY_DEBUG_OPEN"], "the debug gem switches bin/dev sets must reach foreman"
  end

  def test_control_bin_dev_without_the_scrub_leaks
    assert_control_leaks(launch_bin_dev(control: true), "bin/dev")
  end

  def launch_ecosystem_servers(control: false)
    Dir.mktmpdir("ecosystem-servers-env") do |dir|
      dump = File.join(dir, "env.out")
      stubs = File.join(dir, "stubs")
      FileUtils.mkdir_p([stubs, File.join(dir, "projects", "fake-app")])
      stub(stubs, "bundle", "env > #{dump}")
      stub(stubs, "lsof", "exit 0")
      stub(stubs, "curl", "printf 200")
      bin_dir = control ? control_child_env(File.join(dir, "bin")) : File.join(ROOT, "bin")
      script = <<~SH
        source "#{File.join(ROOT, "bin/ecosystem-build")}" >/dev/null 2>&1
        export PATH="#{stubs}:$PATH"
        sleep(){ :; }
        BIN_DIR="#{bin_dir}"
        PROJECTS_DIR="#{File.join(dir, "projects")}"
        RAILS_APPS=(fake-app)
        RAILS_PORTS=(39555)
        phase_servers
      SH
      out, = Open3.capture2e(base_env("STUB_PATH" => stubs, "HOME" => dir), "bash", "-c", script, unsetenv_others: true)
      assert File.size?(dump), "phase_servers never started the stub server:\n#{out}"
      read_env(dump)
    end
  end

  def test_ecosystem_build_starts_the_primaries_under_the_allow_list
    assert_scrubbed(launch_ecosystem_servers, "bin/ecosystem-build phase_servers")
  end

  def test_control_ecosystem_build_without_the_scrub_leaks
    assert_control_leaks(launch_ecosystem_servers(control: true), "bin/ecosystem-build phase_servers")
  end

  # ------------------------------------------------- the mail rule (N4) -------

  def test_mail_keys_reach_a_desk_server_only_as_the_empty_blank
    env = { "PATH" => "/bin", "RESEND_API_KEY" => "fake-real-resend" }
    kept = ChildEnv.desk_server({ "SES_SMTP_PASSWORD" => "fake-from-stack", "SES_SMTP_USERNAME" => "" }, env)

    assert_equal "", kept["RESEND_API_KEY"], "a set parent value is blanked, so dotenv cannot fill it either"
    assert_equal "", kept["SES_SMTP_PASSWORD"], "a set stack value is blanked"
    assert_equal "", kept["SES_SMTP_USERNAME"], "an empty desk blank is kept"
    refute ChildEnv.desk_server({}, { "PATH" => "/bin" }).key?("RESEND_API_KEY"), "an absent key stays absent"
  end

  def test_control_without_the_mail_rule_a_stack_value_passes
    values = { "SES_SMTP_PASSWORD" => "fake-from-stack" }
    pre_fix = ChildEnv.build(values, { "PATH" => "/bin" }, allow: ChildEnv::DESK_SERVER_ALLOW)

    assert_equal "fake-from-stack", pre_fix["SES_SMTP_PASSWORD"],
                 "without the mail rule an explicit stack value reaches the server; the rule is what stops it"
  end
end
