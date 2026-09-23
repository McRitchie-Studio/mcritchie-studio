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

  # THE CELL THE ROW ALONE GETS WRONG. `fresh_success?` cannot tell "this run
  # succeeded" from "some run succeeded today", so a CRASHED seed reads green
  # whenever an earlier run that day left a fresh row. Measured against
  # origin/accepted: the old `&&` chain logged FAILED in exactly this cell.
  def test_a_crashed_seed_is_not_excused_by_an_earlier_fresh_success
    out = phase(fresh_success: true, seed_exit: 1)

    refute_match(/athletes with espn_id/, out,
                 "a seed that exited non-zero must not log the green count just " \
                 "because an earlier run that day left a fresh ImportRun")
  end

  # THE CELL BOTH SIGNALS STILL GOT WRONG, and the reason `since` exists. On the
  # SECOND rebuild of a day the seed can exit 0 with its own run recorded
  # `failed` — Nflverse::SeedPlayers rescues FeedUnavailable and returns — while
  # this morning's `ok` row still satisfies a bare 24-hour window. Measured
  # against the real service before the fix: exit 0, rows "ok | failed",
  # fresh_success? true, phase GREEN through a total outage.
  #
  # The stub answers the freshness question the way the DATABASE would in that
  # world: a whole-day question finds this morning's success, a question pinned
  # to this run's start finds nothing. A phase that forgot to pass a boundary
  # therefore gets the green it used to get, and this test fails.
  def test_an_earlier_success_that_day_no_longer_excuses_a_rescued_outage
    out = phase(fresh_success: true, bounded_fresh_success: false)

    assert_match(/no successful ImportRun/i, out,
                 "a run whose own import never succeeded must not inherit an earlier " \
                 "run's success from the same day")
    refute_match(/athletes with espn_id/, out)
  end

  # The boundary has to be a REAL timestamp, not an empty string the phase
  # happened to export. `ENV.fetch` would blow up on an unset var and
  # `ImportRun.boundary_for` refuses an unreadable one, so either mistake turns
  # the lane red for the wrong reason — which is invisible on the test above,
  # since that test wants red anyway.
  def test_the_phase_passes_a_readable_iso_8601_boundary
    boundary = nil
    phase(fresh_success: true, capture_boundary: ->(value) { boundary = value })

    assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/, boundary.to_s,
                 "phase 6c must hand the predicate the moment the seed started, " \
                 "in the shape Time.zone.iso8601 accepts; got #{boundary.inspect}")
  end

  # --- nfl:upload_headshots ------------------------------------------------

  # THE FAILURE PHASE 6C'S OWN SEED MESSAGE TELLS OPERATORS TO CHECK, and that
  # no phase could report. The task rescues per athlete so one dead headshot URL
  # cannot cost the other thousand theirs, then ended on `puts` — so a
  # credential failure, which fails EVERY athlete, exited 0. Measured with three
  # manufactured candidates and Studio::ImageCache.cache! raising the real
  # Aws::Errors::MissingCredentialsError: failed 3, cached 0, exit 0.
  def test_a_failing_headshot_upload_reaches_the_rebuild_log
    out = phase(fresh_success: true, headshots_exit: 1)

    assert_match(/nfl:upload_headshots failed/i, out)
    assert_match(/AWS_ACCESS_KEY_ID/, out,
                 "the line has to name the credential an operator goes and checks")
    refute_match(/cached variants/, out,
                 "the cached-variant count is a LEVEL — it survives a failed upload " \
                 "untouched, so it must not print as this run's result")
  end

  # The green twin, differing by exactly the upload's exit code.
  def test_a_healthy_headshot_upload_still_logs_its_variant_count
    out = phase(fresh_success: true, headshots_exit: 0)

    assert_match(/cached variants/, out)
    refute_match(/nfl:upload_headshots failed/i, out)
  end

  private

  # Drive phase_nfl_headshots with a stubbed `bundle`.
  #
  # The stub answers by INSPECTING ITS ARGUMENTS, so it does not care what order
  # the phase runs its commands in — a positional stub would have to be rewritten
  # by anyone who reorders the phase, and would pass for the wrong reason if they
  # forgot.
  #
  # `bounded_fresh_success` is the answer the DB would give once the question is
  # pinned to this run's start; it defaults to `fresh_success` so every existing
  # case keeps describing the world it was written for.
  def phase(fresh_success:, refused: 0, seed_stderr: nil, seed_exit: 0,
            bounded_fresh_success: nil, capture_boundary: nil, headshots_exit: 0)
    bounded_fresh_success = fresh_success if bounded_fresh_success.nil?
    Dir.mktmpdir("ecosystem-build-6c") do |tmp|
      stub = File.join(tmp, "bin")
      FileUtils.mkdir_p(stub)
      FileUtils.mkdir_p(File.join(tmp, "mcritchie-studio"))
      boundary_log = File.join(tmp, "boundary")

      File.write(File.join(stub, "bundle"), <<~SH)
        #!/bin/sh
        PATH=/usr/bin:/bin
        args="$*"
        case "$args" in
          *nfl:players_seed*)
            # The outage worlds exit 0 in BOTH worlds — that is the original
            # point. seed_exit drives the OTHER cell: a hard crash.
            #{seed_stderr ? %(echo "#{seed_stderr}" >&2) : ":"}
            echo "seed stdout that the phase discards"
            exit #{seed_exit} ;;
          *fresh_success*)
            # The boundary reaches the stub the same way it reaches the real
            # runner — through the environment — so this branch can tell a
            # whole-day question from one pinned to this run.
            printf '%s' "$SEED_STARTED_AT" > "#{boundary_log}"
            case "$args" in
              *since*) exit #{bounded_fresh_success ? 0 : 1} ;;
              *)       exit #{fresh_success ? 0 : 1} ;;
            esac ;;
          *namesake_collisions_skipped*)
            printf '#{refused.positive? ? ", #{refused} namesake(s) REFUSED — see above" : ""}'
            exit 0 ;;
          *"Athlete.where"*) echo 1234; exit 0 ;;
          *nfl:upload_headshots*) exit #{headshots_exit} ;;
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
      capture_boundary&.call(File.exist?(boundary_log) ? File.read(boundary_log) : nil)
      out
    end
  end
end
