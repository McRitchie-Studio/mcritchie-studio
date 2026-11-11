# frozen_string_literal: true

# [unit] CiCauseDetector: a same-SHA red then green is a defect with a cause (Alex
# McRitchie, 2026-11-06). The flips come from run rows; the causes from the red job's
# log, classed infra / harness / test / product. Log text is trimmed from real CI jobs
# (2026-11-01..05; test paths renamed so the citation ratchet does not read them).
require "minitest/autorun"
require_relative "../../bin/lib/ci_cause_detector"

class CiCauseDetectorTest < Minitest::Test
  APT_STALL = <<~LOG
    2026-10-26T14:02:10.0000000Z ##[group]Run .github/scripts/apt-retry curl libvips
    2026-10-26T14:09:10.0000000Z ::warning::apt attempt 3 failed or hung; retrying
    2026-10-26T14:22:10.0000000Z ::error::apt-get failed every attempt
  LOG

  # A green test printed this on purpose; the real failure is the named one.
  DST_FAILURE = <<~LOG
    2026-11-01T13:04:10.0000000Z nflverse seed: FEED UNAVAILABLE — data not refreshed (Errno::ECONNREFUSED: Connection refused)
    2026-11-01T13:04:11.0000000Z Failure:
    2026-11-01T13:04:11.0000001Z ContactFlaggedDigestJobTest#test_[integration]_a_flag_older_than_the_window_does_not_send [test/jobs/sample_digest_job_test.rb:38]:
    2026-11-01T13:04:11.0000002Z 0 emails expected, but 1 were sent.
    2026-11-01T13:04:11.0000003Z
    2026-11-01T13:04:11.0000004Z bin/rails test test/jobs/sample_digest_job_test.rb:33
    2026-11-01T13:04:11.0000005Z
  LOG

  PLAYWRIGHT = <<~LOG
    2026-11-03T10:00:00.0000000Z   1) [chromium] › e2e/sample_race.spec.js:240:3 › recast › results fit a phone
    2026-11-03T10:00:00.0000001Z
    2026-11-03T10:00:00.0000002Z     Error: expect(received).toBeLessThanOrEqual(expected)
    2026-11-03T10:00:00.0000003Z     Expected: <= 390
    2026-11-03T10:00:00.0000004Z     Received:    412
    2026-11-03T10:00:00.0000005Z   2) [chromium] › e2e/sample_race.spec.js:301:3 › recast › swaps a cast member
    2026-11-03T10:00:00.0000006Z
    2026-11-03T10:00:00.0000007Z     Error: Timed out 5000ms waiting for expect(locator).toBeVisible()
  LOG

  PRODUCT_ERROR = <<~LOG
    2026-11-04T09:00:00.0000000Z Error:
    2026-11-04T09:00:00.0000001Z BuildIntakeTest#test_answers_once:
    2026-11-04T09:00:00.0000002Z ActionView::Template::Error: undefined method `name' for nil
    2026-11-04T09:00:00.0000003Z     app/views/builds/_turn.html.erb:12:in `block in render'
    2026-11-04T09:00:00.0000004Z
    2026-11-04T09:00:00.0000005Z bin/rails test test/integration/sample_intake_test.rb:9
  LOG

  SERVER_BOOT = <<~LOG
    2026-11-02T08:00:00.0000000Z Error: Timed out waiting 120000ms from config.webServer.
  LOG

  def test_a_rerun_that_passed_is_a_flip_of_its_failed_attempt
    rows = [
      { run_id: 7, attempt: 1, conclusion: "failure", sha: "abc", workflow: "CI" },
      { run_id: 7, attempt: 2, conclusion: "success", sha: "abc", workflow: "CI" }
    ]
    assert_equal [{ red: { run_id: 7, attempt: 1 }, green: { run_id: 7, attempt: 2 }, sha: "abc", workflow: "CI" }],
                 CiCauseDetector.flips(rows)
  end

  def test_two_runs_at_one_sha_one_red_one_green_is_a_flip
    rows = [
      { "run_id" => 8, "attempt" => 1, "conclusion" => "timed_out", "sha" => "def", "workflow" => "CI" },
      { "run_id" => 9, "attempt" => 1, "conclusion" => "success", "sha" => "def", "workflow" => "CI" }
    ]
    assert_equal [{ run_id: 8, attempt: 1 }], CiCauseDetector.flips(rows).map { |f| f[:red] }
  end

  def test_a_red_with_no_green_a_cancel_or_another_workflow_is_no_flip
    rows = [
      { run_id: 1, attempt: 1, conclusion: "failure", sha: "s", workflow: "CI" },
      { run_id: 2, attempt: 1, conclusion: "success", sha: "s", workflow: "Engine CI" },
      { run_id: 3, attempt: 1, conclusion: "cancelled", sha: "t", workflow: "CI" },
      { run_id: 4, attempt: 1, conclusion: "success", sha: "t", workflow: "CI" }
    ]
    assert_empty CiCauseDetector.flips(rows)
  end

  def test_an_apt_stall_is_infra
    c = only(CiCauseDetector.causes(job_name: "ci / rails (2)", log: APT_STALL))
    assert_equal ["infra", "apt-mirror"], [c[:klass], c[:key]]
    assert(c[:evidence].any? { |l| l.include?("apt-get failed every attempt") })
  end

  def test_a_named_failure_outranks_a_network_word_a_green_test_printed
    c = only(CiCauseDetector.causes(job_name: "ci / rails (1)", log: DST_FAILURE))
    assert_equal ["test", "ContactFlaggedDigestJobTest"], [c[:klass], c[:key]]
    assert_includes c[:evidence], "0 emails expected, but 1 were sent."
  end

  def test_one_spec_file_failing_at_two_lines_is_one_cause
    c = only(CiCauseDetector.causes(job_name: "ci / playwright (3)", log: PLAYWRIGHT))
    assert_equal ["test", "e2e/sample_race.spec.js"], [c[:klass], c[:key]]
  end

  def test_the_app_raising_under_a_test_is_product
    c = only(CiCauseDetector.causes(job_name: "ci / rails (4)", log: PRODUCT_ERROR))
    assert_equal ["product", "BuildIntakeTest"], [c[:klass], c[:key]]
  end

  def test_a_server_that_never_booted_is_harness
    c = only(CiCauseDetector.causes(job_name: "ci / playwright (1)", log: SERVER_BOOT))
    assert_equal ["harness", "web-server-boot"], [c[:klass], c[:key]]
  end

  UNEXPLAINED = <<~LOG
    2026-11-02T08:00:00.0000000Z ##[group]Run bin/brakeman-ci
    2026-11-02T08:00:01.0000000Z brakeman: 2 new warnings
    2026-11-02T08:00:01.0000001Z ##[error]Process completed with exit code 1.
    2026-11-02T08:00:02.0000000Z Post job cleanup.
    2026-11-02T08:00:02.0000001Z Cleaning up orphan processes
  LOG

  def test_an_unexplained_red_job_is_harness_keyed_by_job_with_its_first_error_line
    c = only(CiCauseDetector.causes(job_name: "ci / static", log: UNEXPLAINED))
    assert_equal ["harness", "job:ci / static"], [c[:klass], c[:key]]
    assert_equal ["brakeman: 2 new warnings", "##[error]Process completed with exit code 1."], c[:evidence]
    refute(c[:evidence].any? { |l| l.include?("cleanup") || l.include?("orphan") })
  end

  def test_a_red_job_with_no_error_line_yields_no_cause
    log = "2026-11-02T08:00:00Z Post job cleanup.\n2026-11-02T08:00:01Z Cleaning up orphan processes\n"
    assert_empty CiCauseDetector.causes(job_name: "ci / static", log: log)
    assert_equal [{ job: "ci / static", cause: nil, follows: nil }],
                 CiCauseDetector.attempt_causes([{ name: "ci / static", log: log }])
  end

  # ── 2026-11-09: one GitHub 504 on ruby/setup-ruby's download, 15 cards. Replayed
  # from the real job logs, trimmed (test/fixtures/files/ci_cause_2026_11_09).
  REPLAY = File.expand_path("../fixtures/files/ci_cause_2026_11_09", __dir__)
  DOWNLOAD_504 = {
    "turf-monster" => { "playwright (3)" => "playwright-3", "static" => "static-a" },
    "mcritchie-studio" => { "ci / rails (3)" => "ci-rails-3", "ci / static" => "ci-static",
                            "ci / playwright (3)" => "ci-playwright-3", "ci / rails plan" => "ci-rails-plan" },
    "cyvasse" => { "ci / system" => "ci-system" },
    "voicebox" => { "scan-js" => "scan-js" },
    "studio-engine" => { "mcritchie-industries suite vs this engine" => "industries-suite",
                         "turf-monster suite vs this engine" => "turf-monster-suite",
                         "moms_app suite vs this engine" => "moms-app-suite",
                         "mcritchie_studio suite vs this engine(shard 4/4)" => "mcritchie-studio-suite-shard-4",
                         "browser lane (playwright) (2)" => "browser-lane-playwright-2" }
  }.freeze

  def replay(repo, file) = File.read(File.join(REPLAY, "#{repo}__#{file}.log"))

  def test_a_setup_ruby_504_is_infra_toolchain_download_not_harness
    c = only(CiCauseDetector.causes(job_name: "voicebox / scan-js", log: replay("voicebox", "scan-js")))
    assert_equal ["infra", "toolchain-download"], [c[:klass], c[:key]]
    assert(c[:evidence].any? { |l| l.include?("ruby-builder/releases/download/ruby-3.3.11") })
    assert_equal "##[error]Error: Unexpected HTTP response: 504", c[:evidence].last
  end

  def test_the_2026_11_09_504_across_five_repos_is_one_outside_cause
    slugs = DOWNLOAD_504.flat_map do |repo, jobs|
      jobs.map do |name, file|
        c = only(CiCauseDetector.causes(job_name: name, log: replay(repo, file)))
        assert_equal ["infra", "toolchain-download"], [c[:klass], c[:key]], "#{repo} #{name}"
        CiCauseDetector.card_slug("McRitchie-Studio/#{repo}", c)
      end
    end
    assert_equal 13, slugs.size
    assert_equal ["ci-cause-infra-toolchain-download"], slugs.uniq
  end

  def test_a_retried_504_that_recovered_is_not_the_fault
    # The census job's own setup-ruby retried past a 504; its red is the census.
    log = replay("studio-engine", "browser-lane-executed-set")
    assert_includes log, "Unexpected HTTP response: 504"
    refute_equal "toolchain-download", only(CiCauseDetector.causes(job_name: "x", log: log))[:key]
  end

  def test_turf_e2e_executed_set_attaches_to_playwright_3
    jobs = [{ name: "playwright (3)", log: replay("turf-monster", "playwright-3") },
            { name: "static", log: replay("turf-monster", "static-b") },
            { name: "e2e_executed_set", log: replay("turf-monster", "e2e_executed_set") }]
    out = CiCauseDetector.attempt_causes(jobs)
    census = out.select { |e| e[:job] == "e2e_executed_set" }
    assert_equal [["playwright (3)", "toolchain-download"]], census.map { |e| [e[:follows], e[:cause][:key]] }
    assert_equal 3, out.size
  end

  def test_two_census_lanes_with_the_same_shard_each_follow_their_own_lane
    jobs = { "ci / playwright (3)" => "ci-playwright-3", "ci / static" => "ci-static", "ci / rails (3)" => "ci-rails-3",
             "ci / e2e_executed_set" => "ci-e2e_executed_set", "ci / rails_executed_set" => "ci-rails_executed_set" }
           .map { |name, file| { name: name, log: replay("mcritchie-studio", file) } }
    follows = CiCauseDetector.attempt_causes(jobs).select { |e| e[:follows] }.to_h { |e| [e[:job], e[:follows]] }
    assert_equal({ "ci / e2e_executed_set" => "ci / playwright (3)", "ci / rails_executed_set" => "ci / rails (3)" }, follows)
  end

  def test_studio_engine_census_jobs_follow_their_dropped_shard
    browser = CiCauseDetector.attempt_causes(
      [{ name: "browser lane (playwright) (2)", log: replay("studio-engine", "browser-lane-playwright-2") },
       { name: "browser lane executed-set", log: replay("studio-engine", "browser-lane-executed-set") }]
    )
    assert_equal ["browser lane (playwright) (2)"], browser.filter_map { |e| e[:follows] }
    rails = CiCauseDetector.attempt_causes(
      [{ name: "mcritchie_studio suite vs this engine(shard 4/4)", log: replay("studio-engine", "mcritchie-studio-suite-shard-4") },
       { name: "moms_app suite vs this engine", log: replay("studio-engine", "moms-app-suite") },
       { name: "mcritchie_studio executed-set", log: replay("studio-engine", "mcritchie-studio-executed-set") }]
    )
    assert_equal ["mcritchie_studio suite vs this engine(shard 4/4)"], rails.filter_map { |e| e[:follows] }
    assert_equal ["toolchain-download"], rails.map { |e| e[:cause][:key] }.uniq
  end

  def test_a_census_with_no_failed_shard_to_follow_is_read_as_its_own_job
    out = CiCauseDetector.attempt_causes([{ name: "e2e_executed_set", log: replay("turf-monster", "e2e_executed_set") }])
    e = only(out)
    assert_nil e[:follows]
    assert_equal ["harness", "job:e2e_executed_set"], [e[:cause][:klass], e[:cause][:key]]
    assert(e[:cause][:evidence].any? { |l| l.include?("##[error]") })
  end

  def test_missing_shards_reads_both_census_spellings
    assert_equal [3], CiCauseDetector.missing_shards(replay("turf-monster", "e2e_executed_set"))
    assert_equal [4], CiCauseDetector.missing_shards(replay("studio-engine", "mcritchie-studio-executed-set"))
    assert_equal [2, 4], CiCauseDetector.missing_shards("  · missing receipts for shard(s) 2, 4 of 4\n")
    assert_empty CiCauseDetector.missing_shards(UNEXPLAINED)
  end

  def test_an_ambiguous_shard_sibling_is_never_guessed
    assert_nil CiCauseDetector.shard_sibling("lint executed-set", 2, ["a (2)", "b (2)"])
  end

  def test_site_identity_still_yields_its_own_test_cause
    c = only(CiCauseDetector.causes(job_name: "browser lane (playwright) (3)", log: replay("studio-engine", "site-identity")))
    assert_equal ["test", "e2e/sample_identity.spec.js"], [c[:klass], c[:key]]
    assert_equal "ci-cause-studio-engine-e2e-sample-identity-spec-js", CiCauseDetector.card_slug("McRitchie-Studio/studio-engine", c)
  end

  def test_a_gem_the_index_lost_is_an_outside_gem_index_cause
    c = only(CiCauseDetector.causes(job_name: "ci / rails (1)", log: replay("mcritchie-studio", "gem-index")))
    assert_equal ["infra", "gem-index"], [c[:klass], c[:key]]
    assert_equal "ci-cause-infra-gem-index", CiCauseDetector.card_slug("McRitchie-Studio/mcritchie-studio", c)
  end

  def test_every_class_is_one_of_the_four
    [APT_STALL, DST_FAILURE, PLAYWRIGHT, PRODUCT_ERROR, SERVER_BOOT, replay_1110("playwright-1")].each do |log|
      CiCauseDetector.causes(job_name: "x", log: log).each { |c| assert_includes CiCauseDetector::CLASSES, c[:klass] }
    end
  end

  def test_slug_and_title_are_stable_and_board_shaped
    slug = CiCauseDetector.slug("McRitchie-Studio/mcritchie-studio", "e2e/sample_race.spec.js")
    assert_equal "ci-cause-mcritchie-studio-e2e-sample-race-spec-js", slug
    long = CiCauseDetector.slug("o/r", "SomeVeryLongMinitestClassNameThatGoesOnAndOnForeverAndEverTest")
    assert_operator long.length, :<=, 60
    assert_equal long, CiCauseDetector.slug("o/r", "SomeVeryLongMinitestClassNameThatGoesOnAndOnForeverAndEverTest")
    assert_equal "Find test cause sample_race", CiCauseDetector.title("test", "e2e/sample_race.spec.js")
    assert_equal 4, CiCauseDetector.title("infra", "apt-mirror").split.size
    assert_equal "Find harness cause rails (3)", CiCauseDetector.title("harness", "job:ci / rails (3)")
  end

  # ── 2026-11-10: turf run 42745469708 attempt 1. Shard 1's test server died in a
  # native malloc abort (exit 134); its report still uploaded (if: always()), empty,
  # so the census failed on the COUNT and named no missing shard. Replayed from the
  # real job logs, trimmed (test/fixtures/files/ci_cause_2026_11_10).
  REPLAY_1110 = File.expand_path("../fixtures/files/ci_cause_2026_11_10", __dir__)

  def replay_1110(file) = File.read(File.join(REPLAY_1110, "turf-monster__#{file}.log"))

  def test_a_native_abort_under_the_test_server_is_its_own_harness_key
    c = only(CiCauseDetector.causes(job_name: "playwright (1)", log: replay_1110("playwright-1")))
    assert_equal ["harness", "native-abort"], [c[:klass], c[:key]]
    refute_includes c[:reason], "/up"
    assert_includes c[:evidence], "[WebServer] malloc_consolidate(): unaligned fastbin chunk detected"
  end

  def test_native_abort_keys_exit_134_139_142_and_the_shim_banner
    [
      "Error: Process from config.webServer was not able to start. Exit code: 134\n",
      "Error: Process from config.webServer was not able to start. Exit code: 139\n",
      "Error: Process from config.webServer exited early. Exit code: 142\n",
      "[WebServer] Segmentation fault (core dumped)\n##[error]Process completed with exit code 1.\n",
      "[WebServer] -- native-abort-report: SIGABRT in a Ruby process\n[WebServer] #0 libc.so.6 abort\n" \
      "Error: Timed out waiting 120000ms from config.webServer.\n",
      "[WebServer] [BUG] Segmentation fault at 0x0000000000000010\n" \
      "Error: Process from config.webServer exited early.\n"
    ].each do |log|
      c = only(CiCauseDetector.causes(job_name: "playwright (2)", log: log))
      assert_equal ["harness", "native-abort"], [c[:klass], c[:key]], log
    end
  end

  # Ruby's crash report opens with the crashing frame's location, `file:line: [BUG] ...`
  # (error.c), never a bare `[BUG]` at the line start: the header the old pattern never read.
  def test_ruby_s_real_file_line_bug_header_is_a_native_abort
    ["/home/runner/work/app/vendor/bundle/ruby/3.3.0/gems/pg-1.6.3/lib/pg/connection.rb:944: [BUG] Segmentation fault at 0x0000000000000010\n",
     "[WebServer] /usr/local/bundle/gems/puma-7.2.0/lib/puma/server.rb:312: [BUG] Segmentation fault at 0x0000000000000000\n" \
     "Error: Process from config.webServer exited early.\n",
     "-e:1: [BUG] Segmentation fault\n##[error]Process completed with exit code 1.\n"].each do |log|
      c = only(CiCauseDetector.causes(job_name: "ci / rails (1)", log: log))
      assert_equal ["harness", "native-abort"], [c[:klass], c[:key]], log
    end
    refute_match CiCauseDetector::NATIVE_ABORT, "the commit message mentions [BUG] in passing"
  end

  # ── 2026-11-11: studio-engine Consumer CI run 42960720634, job 130327466271 (the
  # turf-monster suite). turf's ci_native_abort_report_test failed: its control child
  # exited 0, and the assertion message QUOTES the glibc text it expected. Replayed
  # from the real job log, trimmed (test/fixtures/files/ci_cause_2026_11_11).
  REPLAY_1111 = File.expand_path("../fixtures/files/ci_cause_2026_11_11", __dir__)

  def test_a_test_that_quotes_a_heap_abort_message_is_a_test_cause_not_a_crash
    log = File.read(File.join(REPLAY_1111, "studio-engine__turf-monster-suite.log"))
    c = only(CiCauseDetector.causes(job_name: "turf_monster", log: log))
    assert_equal %w[test CiNativeAbortReportTest], [c[:klass], c[:key]]
    # Ci::CauseCleanup re-reads stored evidence with NATIVE_ABORT alone, so the
    # evidence itself must not read as a crash either.
    c[:evidence].each { |line| refute_match CiCauseDetector::NATIVE_ABORT, line }
  end

  def test_a_quoted_heap_abort_message_is_never_a_native_abort
    ['Expected "" to include "malloc_consolidate(): unaligned fastbin chunk detected".',
     %q(stderr="double free or corruption (out)"),
     "assert_includes out, 'free(): invalid pointer'"].each do |line|
      refute_match CiCauseDetector::NATIVE_ABORT, line
      log = "#{line}\n##[error]Process completed with exit code 1.\n"
      refute_equal "native-abort", only(CiCauseDetector.causes(job_name: "turf_monster", log: log))[:key], line
    end
    ["malloc_consolidate(): unaligned fastbin chunk detected",
     "[WebServer] malloc(): unsorted double linked list corrupted",
     "free(): invalid pointer", "double free or corruption (!prev)"].each do |line|
      assert_match CiCauseDetector::NATIVE_ABORT, line
    end
  end

  def test_a_server_that_exits_1_or_times_out_stays_web_server_boot
    ["Error: Process from config.webServer was not able to start. Exit code: 1\n",
     "Error: Process from config.webServer was not able to start. Exit code: 1342\n",
     # The host docker CLI prints this on every green run; it is no crash.
     "ERROR: ld.so: object '/opt/native-abort-report.so' from LD_PRELOAD cannot be preloaded: ignored.\n" \
     "Error: Timed out waiting 120000ms from config.webServer.\n"].each do |log|
      assert_equal "web-server-boot", only(CiCauseDetector.causes(job_name: "playwright (2)", log: log))[:key], log
    end
  end

  def test_a_short_count_census_follows_the_failed_shard_of_its_lane
    jobs = [{ name: "playwright (1)", log: replay_1110("playwright-1") },
            { name: "e2e_executed_set", log: replay_1110("e2e_executed_set") }]
    assert_empty CiCauseDetector.missing_shards(jobs.last[:log]), "every report arrived; the census failed on the count"
    out = CiCauseDetector.attempt_causes(jobs)
    assert_equal [["playwright (1)", "native-abort", nil], ["e2e_executed_set", "native-abort", "playwright (1)"]],
                 out.map { |e| [e[:job], e[:cause][:key], e[:follows]] }
  end

  def test_a_short_count_census_follows_only_its_own_lane
    rails_short = "RAILS EXECUTED SET: RED\n  · 210 committed test file(s) executed NOTHING: test/a_test.rb\n" \
                  "##[error]Process completed with exit code 1.\n"
    jobs = [{ name: "ci / playwright (3)", log: SERVER_BOOT }, { name: "ci / rails (3)", log: APT_STALL },
            { name: "ci / e2e_executed_set", log: replay_1110("e2e_executed_set") },
            { name: "ci / rails_executed_set", log: rails_short }]
    follows = CiCauseDetector.attempt_causes(jobs).select { |e| e[:follows] }.to_h { |e| [e[:job], e[:follows]] }
    assert_equal({ "ci / e2e_executed_set" => "ci / playwright (3)", "ci / rails_executed_set" => "ci / rails (3)" }, follows)
  end

  def test_a_census_red_for_another_reason_does_not_follow_a_failed_shard
    other = "E2E EXECUTED SET: RED\n  ✗ 3 spec(s) ran that the contract does not own\n##[error]Process completed with exit code 1.\n"
    out = CiCauseDetector.attempt_causes([{ name: "playwright (1)", log: SERVER_BOOT }, { name: "e2e_executed_set", log: other }])
    census = out.find { |e| e[:job] == "e2e_executed_set" }
    assert_nil census[:follows]
    assert_equal "job:e2e_executed_set", census[:cause][:key]
  end

  private

  def only(list)
    assert_equal 1, list.size, list.inspect
    list.first
  end
end
