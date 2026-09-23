# frozen_string_literal: true

# [integration] bin/ecosystem-build's phase 6b verdicts, EXECUTED.
#
# COMPANION TO ecosystem_build_import_verdict_test.rb, which asks the same
# question of phase 6c. A predicate the phase does not call is exactly as useful
# as no predicate, and these were wiring defects: two of phase 6b's four tasks
# were graded by `&&` on an exit code that could not go non-zero, and all four
# had their stderr sent to /dev/null, so the one human-readable account of a
# failure never reached the rebuild log.
#
# WHAT WAS MEASURED, before any of this was written:
#   * espn:scrape_depth_charts with fetch_groups stubbed to nil for all 32 teams
#     printed `{:teams_failed=>32}` and exited 0. The service tolerates a dead
#     team on purpose; nothing above it turned 32 of 32 into a verdict.
#   * nfl:rankings_compute with AthleteGrade emptied wrote the SAME 448 rows as
#     a healthy run and exited 0 — 448 scores of 0.0 against 442 distinct
#     values spanning 49.6..5604.37. The row count this phase logs is identical
#     in both worlds.
#
# So `bundle` is stubbed and the phase is asked for its verdict in each world.
# Every red case below has a green twin differing by exactly one thing, because
# a check that answers the same in both worlds is not a check.
require "bundler/setup"
require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"

class EcosystemBuildNflDataVerdictTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  SCRIPT = File.join(ROOT, "bin/ecosystem-build")

  # --- espn:scrape_depth_charts -------------------------------------------

  def test_a_total_espn_outage_makes_phase_6b_report_failure
    out = phase(espn_exit: 1)

    assert_match(/espn:scrape_depth_charts applied no teams/i, out,
                 "a scrape that applied nothing has to reach the rebuild log as a FAILURE")
    refute_match(/entries with ESPN formation_slot/, out,
                 "the green entry count is a LEVEL — it survives an outage untouched, " \
                 "so it must not print for a scrape that never happened")
  end

  # The healthy world, differing from the one above by EXACTLY the scrape's exit
  # code. If both passed under the old `&&` the experiment would prove nothing.
  def test_a_healthy_scrape_still_logs_its_entry_count
    out = phase(espn_exit: 0)

    assert_match(/entries with ESPN formation_slot/, out)
    refute_match(/applied no teams/i, out)
  end

  # The failure line has to say what an operator does next. A bare
  # "espn:scrape_depth_charts failed" sends them to re-run it by hand to find
  # out that the depth charts are untouched and the rosters snapshotted after
  # it are last week's.
  def test_the_depth_chart_failure_names_its_consequence
    out = phase(espn_exit: 1)

    assert_match(/depth charts are UNCHANGED/i, out)
    assert_match(/last week/i, out)
  end

  # stderr is where the task writes its per-bucket tally, and the old
  # `>/dev/null 2>&1` threw it away — leaving an entry count as the only
  # surviving signal, a number that looks the same whether ESPN served 32 teams
  # or none. ASSERTED ON THE TASK'S OWN WORDS, not on the phase's: the phase's
  # log_fail line is printed whether or not stderr survived, so an assertion on
  # its text passes in both worlds and proves nothing.
  def test_the_scrape_tally_reaches_the_rebuild_log
    tally = "espn:scrape_depth_charts: 0 of 32 teams applied (32 failed, 0 partial, 0 unknown abbrev)"
    out = phase(espn_exit: 1, espn_stderr: tally)

    assert_match(/0 of 32 teams applied \(32 failed/, out,
                 "the only account of WHICH bucket the teams fell into must not be discarded")
  end

  # --- nfl:rankings_compute ------------------------------------------------

  def test_a_degenerate_ranking_makes_phase_6b_report_failure
    out = phase(rankings_exit: 1)

    assert_match(/nfl:rankings_compute failed/i, out)
    refute_match(/rank rows populated/, out,
                 "the row count is identical with and without grades, so it must not " \
                 "print for a run the task refused")
  end

  def test_a_healthy_ranking_still_logs_its_row_count
    out = phase(rankings_exit: 0)

    assert_match(/rank rows populated/, out)
    refute_match(/nfl:rankings_compute failed/i, out)
  end

  # GRADES_FROM is the knob that fixes the all-zero case, so the failure line
  # has to name it rather than leave an operator guessing between "the season
  # does not exist" and "the season has no grades".
  def test_the_ranking_failure_names_the_grade_season
    out = phase(rankings_exit: 1)

    assert_match(/2025-nfl/, out, "the default GRADES_FROM is last season; name it")
    assert_match(/AthleteGrade/, out)
  end

  private

  # Drive phase_nfl_data with a stubbed `bundle`.
  #
  # The stub answers by INSPECTING ITS ARGUMENTS, so reordering the phase cannot
  # silently change which command a case is exercising.
  def phase(espn_exit: 0, rankings_exit: 0, espn_stderr: nil)
    Dir.mktmpdir("ecosystem-build-6b") do |tmp|
      stub = File.join(tmp, "bin")
      FileUtils.mkdir_p(stub)
      FileUtils.mkdir_p(File.join(tmp, "mcritchie-studio"))

      File.write(File.join(stub, "bundle"), <<~SH)
        #!/bin/sh
        PATH=/usr/bin:/bin
        args="$*"
        case "$args" in
          *espn:scrape_depth_charts*)
            #{espn_stderr ? %(echo "#{espn_stderr}" >&2) : ":"}
            echo "scrape stdout that the phase discards"
            exit #{espn_exit} ;;
          *nfl:rankings_compute*)   exit #{rankings_exit} ;;
          *nfl:schedule_seed*)      exit 0 ;;
          *nfl:rosters_snapshot*)   exit 0 ;;
          *DepthChartEntry*)        echo 4321; exit 0 ;;
          *TeamRanking*)            echo 448;  exit 0 ;;
          *Game.where*)             echo 272;  exit 0 ;;
          *Roster.where*)           echo 32;   exit 0 ;;
          *)                        exit 0 ;;
        esac
      SH
      FileUtils.chmod(0o755, File.join(stub, "bundle"))

      script = <<~BASH
        source "#{SCRIPT}"
        PATH="#{stub}:/usr/bin:/bin"
        phase_nfl_data
      BASH

      env = { "HOME" => tmp, "PROJECTS_DIR" => tmp, "NFL_YEAR" => "2026" }
      out, = Open3.capture2e(env, "bash", "-c", script)
      out
    end
  end
end
