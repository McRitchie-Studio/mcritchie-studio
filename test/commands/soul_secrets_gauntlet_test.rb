# frozen_string_literal: true

# [integration] The devnet gauntlet reads its wallets from Avi's soul set
# (soul-secret-sets). bin/release.rb is loaded in a child process; its prepare
# step warms Avi's set with a stub `op` that answers, then the stub is rewritten
# to HANG, and the gauntlet step runs a stand-in driver that does exactly what
# turf-monster's KeyStore does: `op item get <title> --vault studio-agents
# --format json`, with `op` resolved on PATH.
#
# Without the fix the driver's `op` is the hanging stub and the step is killed at
# its deadline. With it, bin/shims/op-cache/op answers from the cache and the
# stalled op is never called. FAKE values only; no real 1Password read, and never
# the operator's real <projects>/.secret-cache (CLAUDE_PROJECTS_DIR is a tmpdir,
# the sandbox is armed).
#
#   ruby -Itest test/commands/soul_secrets_gauntlet_test.rb

require "minitest/autorun"
require "json"
require "open3"
require "tmpdir"
require "fileutils"
require_relative "../support/session_env"
require_relative "../support/outbound_seams"

class SoulSecretsGauntletTest < Minitest::Test
  RELEASE = File.expand_path("../../bin/release.rb", __dir__)
  FAKE_ADDR = "FAKEGAUNTLETADDRESS"
  FAKE_KEY = "FAKE-GAUNTLET-KEY-not-a-secret"

  def setup
    @root = Dir.mktmpdir("soul-gauntlet")
    @op_log = File.join(@root, "op-calls.log")
    @bin = File.join(@root, "bin")
    FileUtils.mkdir_p(@bin)
    @op = File.join(@bin, "op")
    write_op(answering: true)
    @driver = File.join(@root, "driver")
    # The stand-in driver: KeyStore's own call, `op` from PATH, then the address.
    File.write(@driver, <<~SH)
      #!/bin/sh
      for item in solana.mack.agent solana.turf.agent; do
        op item get "$item" --vault studio-agents --format json > "#{@root}/$item.json" || exit 9
      done
      ruby -rjson -e 'puts "DRIVER-READ " + JSON.parse(File.read(ARGV[0]))["fields"].find { |f| f["label"] == "wallet-address" }["value"]' "#{@root}/solana.mack.agent.json"
    SH
    File.chmod(0o755, @driver)
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  # The stub never echoes a token (the ambient one is real); it logs its argv.
  def write_op(answering:)
    body = if answering
             json = JSON.generate("fields" => [{ "label" => "private-key", "value" => FAKE_KEY },
                                               { "label" => "wallet-address", "value" => FAKE_ADDR }])
             "cat <<'JSON'\n#{json}\nJSON"
           else
             "exec sleep 60"
           end
    File.write(@op, "#!/bin/sh\necho \"$*\" >> #{@op_log}\n#{body}\n")
    File.chmod(0o755, @op)
  end

  def run_release(script)
    env = OutboundSeams.env(
      "CLAUDE_PROJECTS_DIR" => @root, "TASK_USAGE_SANDBOX" => "1", "MCR_SECRET_CACHE_DIR" => nil,
      "MCR_SOUL_SECRET_SETS" => nil, "MCR_OP_READS_LOG" => File.join(@root, "op-reads.log"),
      "SECRET_OP_BIN" => @op, "MCR_OP_DEADLINE" => "1", "RELEASE_GAUNTLET_WARM" => "1",
      "RELEASE_GAUNTLET_DRIVER" => @driver, "RELEASE_GAUNTLET_STEP_DEADLINE" => "15",
      "PATH" => [@bin, OutboundSeams.sealed_path].join(File::PATH_SEPARATOR)
    )
    Open3.capture3(env, "ruby", "-e", "load #{RELEASE.inspect}\n#{script}")
  end

  def op_calls
    File.exist?(@op_log) ? File.read(@op_log).lines.map(&:strip) : []
  end

  def test_integration_a_release_with_op_hanging_after_the_warm_still_runs_the_gauntlet
    script = <<~RUBY
      warm_gauntlet_secrets!
      File.write(#{@op.inspect}, "#!/bin/sh\\necho \\"$*\\" >> #{@op_log}\\nexec sleep 60\\n")
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      out, ok = run_gauntlet_step(#{@root.inspect}, [])
      puts "STEP ok=\#{ok} took=\#{(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(1)}"
      puts out
    RUBY
    out, err, status = run_release(script)

    assert status.success?, err
    assert_match(/STEP ok=true/, out)
    assert_includes out, "DRIVER-READ #{FAKE_ADDR}"
    assert_equal 2, op_calls.size, "the warm read each wallet once; the hanging op was never called: #{op_calls.inspect}"
    assert(op_calls.all? { |c| c.start_with?("item get solana.") })
    took = out[/took=([\d.]+)/, 1].to_f
    assert_operator took, :<, 10, "the step read the cache, it did not wait on op"
    [out, err].each { |text| refute_includes text, FAKE_KEY }
  end

  # The control: the same step with nothing warmed and op hanging is the night of
  # 2026-11-08 in miniature. The driver gets no wallet, so the gauntlet goes red
  # in bounded time instead of hanging.
  def test_integration_with_nothing_warmed_a_hung_op_turns_the_step_red_in_bounded_time
    write_op(answering: false)
    script = <<~RUBY
      out, ok = run_gauntlet_step(#{@root.inspect}, [])
      puts "STEP ok=\#{ok}"
      puts out
    RUBY
    out, err, status = run_release(script)

    assert status.success?, err
    assert_match(/STEP ok=false/, out)
    refute_includes out, "DRIVER-READ"
  end

  def test_integration_the_driver_env_puts_the_shim_first_and_names_the_real_op
    out, err, status = run_release("puts JSON.generate(gauntlet_child_env)")
    assert status.success?, err
    child = JSON.parse(out.lines.last)

    assert_equal File.expand_path("../../bin/shims/op-cache", __dir__), child["PATH"].split(":").first
    assert_equal "avi", child["MCR_OP_SHIM_SOUL"]
    assert_equal @op, child["MCR_OP_SHIM_REAL"]
    assert child.key?("RUBYOPT") && child["RUBYOPT"].nil?, "the Bundler scrub is kept"
  end
end
