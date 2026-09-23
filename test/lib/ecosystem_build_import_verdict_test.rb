# frozen_string_literal: true

# [integration] bin/ecosystem-build's phase 6c verdict, EXECUTED.
#
# WHY IT IS NOT ENOUGH TO TEST ImportRun.fresh_success?. That predicate has its
# own unit matrix (test/models/import_run_test.rb) and it is right. This file
# asks the other question, the one a unit test structurally cannot: is it WIRED?
# A correct predicate the phase does not call is exactly as useful as no
# predicate, and the defect being fixed here was precisely a wiring defect —
# the phase graded a service by `&&` on an exit code that had stopped meaning
# anything.
#
# THE REGRESSION, in one sentence. Nflverse::SeedPlayers rescues a feed outage
# and RETURNS rather than raising — deliberately, because it is a declared
# post_deploy_cmd and a dead upstream must not abort a ship — so
# `rails nfl:players_seed` exits 0 whether it read the feed or never reached it.
# Chained with `&&`, phase 6c therefore logged a GREEN "0 athletes with espn_id"
# on a fresh-Mac rebuild during an outage, where it used to log FAILED.
#
# So `bundle` is stubbed, and the phase is asked for its verdict in both worlds.
# The stub makes the SEED SUCCEED in both — that is the whole point, and a stub
# that failed the seed on the outage path would be testing a world this bug does
# not live in.
require "bundler/setup"
require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"

class EcosystemBuildImportVerdictTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  SCRIPT = File.join(ROOT, "bin/ecosystem-build")

  # The outage world: the seed exits 0, and no fresh successful ImportRun exists.
  def test_a_feed_outage_makes_phase_6c_report_failure
    out = phase(fresh_success: false)

    assert_match(/no successful ImportRun/i, out,
                 "an outage has to reach the rebuild log as a FAILURE — the exit code " \
                 "stopped discriminating when the importer started rescuing the outage")
    refute_match(/athletes with espn_id/, out,
                 "the green line must not print for a run that never read the feed")
  end

  # The healthy world, which differs from the one above by EXACTLY the ImportRun
  # row — same seed command, same exit code 0. If this passed while the test
  # above also passed on the old `&&` chain, the experiment would not separate
  # the two states and would prove nothing.
  def test_a_healthy_import_makes_phase_6c_report_success
    out = phase(fresh_success: true)

    assert_match(/athletes with espn_id/, out, "a real import still logs its count")
    refute_match(/no successful ImportRun/i, out)
  end

  # Card 1's data feeding card 2's log: a run that REFUSED humans is not the same
  # event as a clean one, and an athlete count alone cannot show the difference.
  def test_a_refusing_import_names_the_refusals_beside_the_count
    out = phase(fresh_success: true, refused: 2)

    assert_match(/athletes with espn_id/, out)
    assert_match(/2 namesake\(s\) REFUSED/, out,
                 "the count alone cannot distinguish a clean import from one that " \
                 "declined to write two humans")
  end

  # stderr is the channel the service uses for FEED UNAVAILABLE and for its
  # refusals, and the old chain's `2>&1` threw it away — leaving a number as the
  # only surviving signal. Assert the phase no longer swallows it.
  # ASSERTED ON "data not refreshed", NOT ON "FEED UNAVAILABLE", and the
  # difference is the whole test. The phase's own log_fail line says "read the
  # FEED UNAVAILABLE line above", so an assertion on that phrase matches the
  # phase's text whether or not the service's stderr survived — it passes in
  # both worlds and proves nothing. Measured: with `2>&1` restored so stderr IS
  # discarded, the obvious version of this test stayed GREEN. The tail of the
  # warning appears only in what the service wrote.
  def test_the_feed_unavailable_warning_reaches_the_rebuild_log
    warning = "nflverse seed: FEED UNAVAILABLE — data not refreshed (SocketError: getaddrinfo)"
    out = phase(fresh_success: false, seed_stderr: warning)

    assert_match(/data not refreshed \(SocketError: getaddrinfo\)/, out,
                 "the only human-readable account of the failure must not be discarded — " \
                 "under the old `2>&1` an athlete count was the single surviving signal")
  end

  private

  # Drive phase_nfl_headshots with a stubbed `bundle`.
  #
  # The stub answers by INSPECTING ITS ARGUMENTS, so it does not care what order
  # the phase runs its commands in — a positional stub would have to be rewritten
  # by anyone who reorders the phase, and would pass for the wrong reason if they
  # forgot.
  def phase(fresh_success:, refused: 0, seed_stderr: nil)
    Dir.mktmpdir("ecosystem-build-6c") do |tmp|
      stub = File.join(tmp, "bin")
      FileUtils.mkdir_p(stub)
      FileUtils.mkdir_p(File.join(tmp, "mcritchie-studio"))

      File.write(File.join(stub, "bundle"), <<~SH)
        #!/bin/sh
        PATH=/usr/bin:/bin
        args="$*"
        case "$args" in
          *nfl:players_seed*)
            # THE POINT OF THE WHOLE TEST: the seed exits 0 in BOTH worlds.
            #{seed_stderr ? %(echo "#{seed_stderr}" >&2) : ":"}
            echo "seed stdout that the phase discards"
            exit 0 ;;
          *fresh_success*)   exit #{fresh_success ? 0 : 1} ;;
          *namesake_collisions_skipped*)
            printf '#{refused.positive? ? ", #{refused} namesake(s) REFUSED — see above" : ""}'
            exit 0 ;;
          *"Athlete.where"*) echo 1234; exit 0 ;;
          *nfl:upload_headshots*) exit 0 ;;
          *ImageCache*)      echo 99; exit 0 ;;
          *)                 exit 0 ;;
        esac
      SH
      FileUtils.chmod(0o755, File.join(stub, "bundle"))

      script = <<~BASH
        source "#{SCRIPT}"
        PATH="#{stub}:/usr/bin:/bin"
        phase_nfl_headshots
      BASH

      env = { "HOME" => tmp, "PROJECTS_DIR" => tmp, "WITH_NFL_HEADSHOTS" => "1" }
      out, = Open3.capture2e(env, "bash", "-c", script)
      out
    end
  end
end
