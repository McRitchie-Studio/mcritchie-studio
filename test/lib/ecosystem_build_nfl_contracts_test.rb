require "minitest/autorun"
require "open3"
require "shellwords"
require "tmpdir"
require "fileutils"

# [unit] A keyless first rebuild seeds no Spotrac contracts and db:seed still
# exits 0, so the rebuild has to read the row. Sources the real script, with
# `bundle` standing in for the runner, and drives the real phase wiring.
class EcosystemBuildNflContractsTest < Minitest::Test
  SCRIPT = File.expand_path("../../bin/ecosystem-build", __dir__)

  def run_check(answer, env: {}, runner: nil)
    stub = runner || %(echo "noise"; echo #{answer.to_s.shellescape})
    script = <<~BASH
      source #{SCRIPT.shellescape} >/dev/null 2>&1
      bundle() { #{stub}; }
      assert_nfl_contracts /hub
      echo "rc=$?"
    BASH
    Open3.capture2e(env, "bash", "-c", script).first
  end

  def test_passes_with_contracts
    out = run_check(2519)
    assert_includes out, "rc=0"
    assert_includes out, "2519"
  end

  def test_fails_with_none_and_names_the_keys_and_the_recovery
    out = run_check(0)
    assert_includes out, "rc=1"
    assert_includes out, "r2.mcritchie-studio"
    assert_includes out, "bin/rails db:seed"
  end

  def test_an_unreadable_count_fails_rather_than_passing
    assert_includes run_check("", runner: "return 1"), "rc=1"
    assert_includes run_check("boom"), "rc=1"
  end

  def test_skip_network_seeds_passes_and_says_so
    out = run_check(0, env: { "SKIP_NETWORK_SEEDS" => "1" })
    assert_includes out, "rc=0"
    assert_includes out, "SKIP_NETWORK_SEEDS=1"
    assert_includes out, "roster spots are empty"
  end

  # The phase's body is a subshell, so a failure inside it has to reach the
  # parent or `main` goes on to print "Ecosystem at steady state".
  def test_a_failed_check_stops_the_build_before_steady_state
    Dir.mktmpdir do |dir|
      hub = File.join(dir, "mcritchie-studio")
      FileUtils.mkdir_p(File.join(hub, "config"))
      File.write(File.join(hub, "config/database.yml"), "development:\n  database: some_db\n")
      script = <<~BASH
        source #{SCRIPT.shellescape} >/dev/null 2>&1
        PROJECTS_DIR=#{dir.shellescape}
        RAILS_APPS=(mcritchie-studio)
        bundle() { case "$1 $2" in "check "*) return 0 ;; esac; echo 0; }
        ruby() { echo some_db; }
        phase_bundles_dbs
        echo "REACHED STEADY STATE"
      BASH
      out, status = Open3.capture2e("bash", "-c", script)
      assert_equal 1, status.exitstatus, out
      assert_includes out, "Stopped at Phase 6"
      refute_includes out, "REACHED STEADY STATE"
    end
  end
end
