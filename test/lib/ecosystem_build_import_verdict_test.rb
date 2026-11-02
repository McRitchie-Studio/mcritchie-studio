# frozen_string_literal: true

# [integration] bin/ecosystem-build's phase 6c verdict, EXECUTED. ImportRun.fresh_success? has
# its own matrix (test/models/import_run_test.rb); this asks whether it is WIRED.
# Nflverse::SeedPlayers rescues a feed outage and RETURNS, deliberately (a declared
# post_deploy_cmd; a dead upstream must not abort a ship), so `rails nfl:players_seed` exits 0
# either way and `&&` on it grades nothing. So `bundle` is stubbed and the phase gives its
# verdict in both worlds. The stub makes the SEED SUCCEED in both: failing it on the outage
# path tests a world this bug does not live in.
# History: task import-run-drops-skip-stats.
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

  # stderr carries FEED UNAVAILABLE and the service's refusals, and `2>&1` throws it away.
  # ASSERTED ON "data not refreshed", NOT ON "FEED UNAVAILABLE": the phase's own log_fail line
  # says "read the FEED UNAVAILABLE line above", so that phrase matches whether or not stderr
  # survived and proves nothing. The tail of the warning appears only in what the service wrote.
  # History: task import-run-drops-skip-stats.
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

  # THE CELL BOTH SIGNALS STILL GOT WRONG, and the reason `since` exists. On a day's SECOND
  # rebuild the seed can exit 0 with its own run recorded `failed` (Nflverse::SeedPlayers
  # rescues FeedUnavailable and returns) while this morning's `ok` row satisfies a bare 24-hour
  # window. The stub answers as the DATABASE would: a whole-day question finds that success, one
  # pinned to this run's start finds nothing. A phase that forgets the boundary gets green, and
  # this test fails.
  # History: task rebuild-lane-grades-dead-exitcodes.
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

    assert_match(/nfl:upload_headshots exited non-zero/i, out)
    assert_match(/R2_ACCESS_KEY_ID/, out,
                 "the line has to name the credential an operator goes and checks: the R2 key, " \
                 "which every hub environment reads since 2026-09-30")
    refute_match(/AWS_[A-Z_]+/, out,
                 "AWS was retired on 2026-10-10; naming its key sends an operator after a credential that no longer exists")
    refute_match(/cached variants/, out,
                 "the cached-variant count is a LEVEL — it survives a failed upload " \
                 "untouched, so it must not print as this run's result")
  end

  # THE PHASE MUST NOT ASSERT A CAUSE IT CANNOT KNOW. An exit code carries one
  # bit, and the task has TWO aborts that blame opposite parties: a wholesale
  # upload failure names AWS credentials, and a run that declined fetchable work
  # says explicitly that it is NOT S3. This line used to state "failed more
  # uploads than it cached — usually AWS creds" over both, so half the time it
  # sent an operator to rotate a working credential. It may name the
  # POSSIBILITIES; it may not pick one.
  def test_the_headshot_failure_does_not_pick_one_of_the_two_causes
    out = phase(fresh_success: true, headshots_exit: 1)

    refute_match(/failed more uploads than it cached/, out,
                 "that sentence is one of the two verdicts, asserted over both")
    assert_match(/NOT S3/, out, "name the other abort, so the operator knows to read which fired")
    assert_match(/stderr above/i, out,
                 "point at the channel that actually carries the verdict")
  end

  # THE CHANNEL CLAIM, PROVEN RATHER THAN ASSERTED. `>/dev/null` takes stdout
  # only, so the task's own verdict — which now carries the per-athlete causes in
  # its body precisely because of this — reaches the rebuild log, and the `[!]`
  # lines it used to tell operators to "read above" do not. Both halves are
  # checked: a line that survived and a line that must not.
  def test_the_headshot_verdict_survives_while_its_stdout_is_discarded
    out = phase(fresh_success: true, headshots_exit: 1,
                headshots_stderr: "nfl:upload_headshots failed 2 of 2 attempted uploads")

    assert_match(/failed 2 of 2 attempted uploads/, out,
                 "the task's own stderr is the only account of WHICH verdict fired")
    refute_match(/headshot stdout that the phase discards/, out,
                 "stdout is thrown away, which is why the causes had to move to stderr")
  end

  # The green twin, differing by exactly the upload's exit code.
  def test_a_healthy_headshot_upload_still_logs_its_variant_count
    out = phase(fresh_success: true, headshots_exit: 0)

    assert_match(/cached variants/, out)
    refute_match(/nfl:upload_headshots exited non-zero/i, out)
  end

  private

  # Drive phase_nfl_headshots with a stubbed `bundle`. The stub answers by INSPECTING ITS
  # ARGUMENTS, so command order does not matter: a positional stub needs rewriting on any
  # reorder and would pass for the wrong reason. `bounded_fresh_success` is the DB's answer once
  # the question is pinned to this run's start; it defaults to `fresh_success`.
  # History: task import-run-drops-skip-stats.
  def phase(fresh_success:, refused: 0, seed_stderr: nil, seed_exit: 0,
            bounded_fresh_success: nil, capture_boundary: nil, headshots_exit: 0,
            headshots_stderr: nil)
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
          *nfl:upload_headshots*)
            # BOTH CHANNELS, so a test can tell which one the phase keeps. The
            # phase redirects stdout to /dev/null and leaves stderr alone, and the
            # task's verdicts rely on exactly that asymmetry.
            #{headshots_stderr ? %(echo "#{headshots_stderr}" >&2) : ":"}
            echo "headshot stdout that the phase discards"
            exit #{headshots_exit} ;;
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
