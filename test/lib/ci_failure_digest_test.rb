# frozen_string_literal: true

# [unit] CiFailureDigest: the failing tests named from the failing jobs' logs, printed
# by bin/submit at 7/8 on a red CI (/tasks/submit-checks-before-push). The log text
# below is trimmed from real CI jobs (2026-10-11/12; test file paths renamed so the
# citation ratchet does not read them as citations), timestamps and colour codes
# kept, because those are what the parser has to see through.
require "minitest/autorun"
require "json"
require_relative "../../bin/lib/ci_failure_digest"

class CiFailureDigestTest < Minitest::Test
  # The one element of a list that must hold exactly one (no ActiveSupport here).
  def only(list)
    assert_equal 1, list.size, list.inspect
    list.first
  end

  # mcritchie-studio job 114643015540 (a Failure, with its rerun line).
  MINITEST_FAILURE = <<~LOG
    2026-10-12T02:56:10.1000000Z Failure:
    2026-10-12T02:56:10.1000001Z InlineScriptAndXDataRatchetTest#test_no_template_has_more_x-data_bindings_or_script_tags_than_its_pin,_or_fewer [test/views/template_pin_ratchet_sample_test.rb:68]:
    2026-10-12T02:56:10.1000002Z templates drifted from their pins:
    2026-10-12T02:56:10.1000003Z   app/views/music_videos/index.html.erb: has no pin ({"x_data"=>1, "script"=>0}); move the behaviour to app/javascript.
    2026-10-12T02:56:10.1000004Z
    2026-10-12T02:56:10.1000005Z bin/rails test test/views/template_pin_ratchet_sample_test.rb:65
    2026-10-12T02:56:10.1000006Z
    2026-10-12T02:56:11.0000000Z 4019 runs, 21893 assertions, 1 failures, 0 errors, 4 skips
  LOG

  # turf-monster job on 2026-10-11 15:09 (an Error: no location in the header).
  MINITEST_ERROR = <<~LOG
    2026-10-11T15:09:26.7681515Z Error:
    2026-10-11T15:09:26.7683417Z SigningCspTest#test_an_admin_gets_the_strict_policy_on_every_signing_page:
    2026-10-11T15:09:26.7684682Z Solana::Client::HttpError: HTTP 429 from RPC: {"jsonrpc":"2.0","error":{"code": 429,"message":"Connection rate limits exceeded"}, "id": 1 }
    2026-10-11T15:09:26.7685766Z     app/services/solana/client_logger.rb:41:in `call'
    2026-10-11T15:09:26.7686650Z     app/services/solana/deadline.rb:126:in `call'
    2026-10-11T15:09:26.7686651Z
    2026-10-11T15:09:26.7686652Z bin/rails test test/integration/signing_csp_test.rb:12
  LOG

  # turf-monster job 114434022255 (Playwright list reporter, retried twice).
  PLAYWRIGHT = <<~LOG
    2026-10-10T22:01:00.0000000Z   \e[31m✘\e[39m   52 [chromium] › e2e/alpine_factory_registration.spec.js:136:3 › Alpine factory registration › seedsBar is whole after a Turbo client-side navigation (1.3s)
    2026-10-10T22:03:00.0000000Z   2) [chromium] › e2e/alpine_factory_registration.spec.js:136:3 › Alpine factory registration › seedsBar is whole after a Turbo client-side navigation
    2026-10-10T22:03:00.0000001Z
    2026-10-10T22:03:00.0000002Z     Error: \e[2mexpect(\e[22m\e[31mreceived\e[39m\e[2m).\e[22mtoBe\e[2m(\e[22m\e[32mexpected\e[39m\e[2m) // Object.is equality\e[22m
    2026-10-10T22:03:00.0000003Z
    2026-10-10T22:03:00.0000004Z     Expected: \e[32mtrue\e[39m
    2026-10-10T22:03:00.0000005Z     Received: \e[31mundefined\e[39m
    2026-10-10T22:03:00.0000006Z
    2026-10-10T22:03:00.0000007Z       122 |     return !!el && !el.__beforeVisit && !!el._x_dataStack;
    2026-10-10T22:03:00.0000008Z     > 124 |   expect(await page.evaluate(() => window.__sameDocument)).toBe(true);
    2026-10-10T22:03:00.0000009Z     Retry #1 ───────────────────────────────────────────────────────
    2026-10-10T22:03:01.0000000Z   3) [chromium] › e2e/alpine_factory_registration.spec.js:136:3 › Alpine factory registration › seedsBar is whole after a Turbo client-side navigation
    2026-10-10T22:03:01.0000001Z     Error: expect(received).toBe(expected) // Object.is equality
  LOG

  # mcritchie-studio job 114640600263 (died in "Initialize containers").
  IMAGE_PULL = <<~LOG
    2026-10-12T02:39:16.6918349Z ##[command]/usr/bin/docker pull public.ecr.aws/docker/library/postgres:17
    2026-10-12T02:39:17.0928241Z Error response from daemon: toomanyrequests: Data limit exceeded
    2026-10-12T02:39:17.0952580Z ##[warning]Docker pull failed with exit code 1, back off 6.601 seconds before retry.
  LOG

  def test_a_minitest_failure_names_the_test_its_line_and_its_message
    f = only(CiFailureDigest.extract(MINITEST_FAILURE)[:failures])

    assert_equal "InlineScriptAndXDataRatchetTest#test_no_template_has_more_x-data_bindings_or_script_tags_than_its_pin,_or_fewer",
                 f[:name]
    assert_equal "test/views/template_pin_ratchet_sample_test.rb:68", f[:location]
    assert_equal "templates drifted from their pins:", f[:excerpt].first
    assert_includes f[:excerpt].last, "app/views/music_videos/index.html.erb: has no pin"
  end

  def test_a_minitest_error_takes_its_location_from_the_rerun_line
    f = only(CiFailureDigest.extract(MINITEST_ERROR)[:failures])

    assert_equal "SigningCspTest#test_an_admin_gets_the_strict_policy_on_every_signing_page", f[:name]
    assert_equal "test/integration/signing_csp_test.rb:12", f[:location]
    assert_match(/\ASolana::Client::HttpError: HTTP 429/, f[:excerpt].first)
  end

  # A test that failed on an HTTP 429 is still a test failure: the infra note is said,
  # but the failure is listed, because the fix (stub the call) is in the code.
  def test_a_rate_limited_test_is_listed_and_the_infra_cause_is_named
    digest = CiFailureDigest.extract(MINITEST_ERROR)
    assert_equal 1, digest[:failures].size
    assert_match(/HTTP 429/, digest[:infra])
  end

  def test_a_playwright_failure_is_reported_once_with_its_expectation_and_no_code_frame
    failures = CiFailureDigest.extract(PLAYWRIGHT)[:failures]

    assert_equal 1, failures.size, "a retried test is one failure"
    f = failures.first
    assert_equal "e2e/alpine_factory_registration.spec.js:136:3 › Alpine factory registration › seedsBar is whole " \
                 "after a Turbo client-side navigation", f[:name]
    assert_equal ["Error: expect(received).toBe(expected) // Object.is equality", "Expected: true", "Received: undefined"],
                 f[:excerpt], "colour codes stripped; the code frame and the retry banner are not excerpted"
  end

  def test_an_image_pull_failure_is_setup_not_a_test
    digest = CiFailureDigest.extract(IMAGE_PULL)

    assert_empty digest[:failures]
    assert_equal "the container image pull was rate-limited", digest[:infra]
    printed = CiFailureDigest.lines([{ job: "ci / rails (1)", failures: [], infra: digest[:infra] }]).join("\n")
    assert_includes printed, "setup, not a test"
    assert_includes printed, "re-run the job"
  end

  def test_lines_list_real_jobs_first_and_name_census_jobs_as_echoes
    jobs = [{ job: "ci / rails_executed_set", failures: [], infra: nil },
            { job: "ci / rails (2)", url: "https://github.com/o/r/actions/runs/1/job/2" }
              .merge(CiFailureDigest.extract(MINITEST_FAILURE))]
    printed = CiFailureDigest.lines(jobs)

    assert_match(/fix all of these before the next push/, printed.first)
    assert_equal "  ci / rails (2)  https://github.com/o/r/actions/runs/1/job/2", printed[1]
    assert(printed.any? { |l| l.include?("✗ InlineScriptAndXDataRatchetTest#") && l.include?("[test/views/") })
    assert_match(/ci \/ rails_executed_set — census job\(s\): they re-count the jobs above/, printed.last)
  end

  def test_nothing_failed_prints_nothing
    assert_empty CiFailureDigest.lines([])
  end

  def test_job_ref_reads_the_repo_and_job_from_a_check_link
    assert_equal ["McRitchie-Studio/turf-monster", "114434022255"],
                 CiFailureDigest.job_ref("https://github.com/McRitchie-Studio/turf-monster/actions/runs/38150000000/job/114434022255")
    assert_nil CiFailureDigest.job_ref("https://example.com/status")
  end

  # [integration] collect against an injected gh: the red `pr checks` list (gh exits
  # non-zero on a red PR, with the JSON on stdout), one log per failing job, the census
  # job not fetched, a passing job ignored.
  def test_collect_reads_each_failing_jobs_log_and_skips_the_census_echo
    checks = [
      { "name" => "ci / rails (2)", "bucket" => "fail", "link" => "https://github.com/o/r/actions/runs/1/job/22" },
      { "name" => "ci / rails_executed_set", "bucket" => "fail", "link" => "https://github.com/o/r/actions/runs/1/job/23" },
      { "name" => "ci / static", "bucket" => "pass", "link" => "https://github.com/o/r/actions/runs/1/job/24" }
    ]
    calls = []
    gh = lambda do |args|
      calls << args
      if args[0, 2] == %w[pr checks] then [JSON.generate(checks), false]
      elsif args[1] == "repos/o/r/actions/jobs/22/logs" then [MINITEST_FAILURE, true]
      else ["unexpected call", false]
      end
    end

    jobs = CiFailureDigest.collect("https://github.com/o/r/pull/9", gh: gh)

    assert_equal ["ci / rails (2)", "ci / rails_executed_set"], jobs.map { |j| j[:job] }
    assert_equal 1, jobs.first[:failures].size
    assert_equal 2, calls.size, "one checks read and one log read; the census job's log is not fetched"
  end

  # A log with a non-UTF-8 byte is still read, and does not blank its neighbour's digest.
  def test_an_invalid_byte_in_one_log_does_not_cost_the_other_jobs
    checks = [{ "name" => "ci / rails (1)", "bucket" => "fail", "link" => "https://github.com/o/r/actions/runs/1/job/7" },
              { "name" => "ci / rails (2)", "bucket" => "fail", "link" => "https://github.com/o/r/actions/runs/1/job/8" }]
    bad = "#{MINITEST_FAILURE}stray \xFF byte\n".dup.force_encoding(Encoding::UTF_8)
    gh = ->(args) { args[0] == "pr" ? [JSON.generate(checks), false] : [args[1].end_with?("/7/logs") ? bad : MINITEST_FAILURE, true] }
    jobs = CiFailureDigest.collect("u", gh: gh)
    assert_equal ["ci / rails (1)", "ci / rails (2)"], jobs.map { |j| j[:job] }
    assert_equal [1, 1], jobs.map { |j| j[:failures].size }, jobs.inspect
  end

  def test_collect_degrades_to_nothing_or_a_note_never_an_exception
    assert_empty CiFailureDigest.collect("u", gh: ->(_args) { ["", true] }), "an empty checks answer prints nothing"
    assert_empty CiFailureDigest.collect("u", gh: ->(_args) { ["HTTP 502", false] })

    checks = [{ "name" => "ci / rails (1)", "bucket" => "fail", "link" => "https://github.com/o/r/actions/runs/1/job/7" }]
    gh = ->(args) { args[0] == "pr" ? [JSON.generate(checks), false] : ["HTTP 410: log expired", false] }
    job = only(CiFailureDigest.collect("u", gh: gh))
    assert_equal "HTTP 410: log expired", job[:unread]
    assert_includes CiFailureDigest.lines([job]).join("\n"), "(log unreadable: HTTP 410: log expired)"
  end
end
